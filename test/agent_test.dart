import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_app/worker/agent.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;

llama.Message toolCall(String name, Map<String, dynamic> args) =>
    llama.Message(role: llama.MessageRole.assistant, content: '', toolCalls: [
      llama.ToolCall(
          function: llama.ToolCallFunction(name: name, arguments: args))
    ]);

const answer =
    llama.Message(role: llama.MessageRole.assistant, content: 'It is 21C.');

void main() {
  marketToolTests();
  test('should run requested tool and return final answer', () async {
    final replies = [
      toolCall('web_search', {'query': 'weather'}),
      answer
    ];
    final history = <llama.Message>[];
    final ranTools = <String>[];
    final result = await runToolLoop(history, (_) async => replies.removeAt(0),
        (name, args) async {
      ranTools.add('$name:${args['query']}');
      return 'sunny';
    });
    expect(result, 'It is 21C.');
    expect(ranTools, ['web_search:weather']);
    expect(history.map((m) => m.role), [
      llama.MessageRole.assistant,
      llama.MessageRole.tool,
      llama.MessageRole.assistant
    ]);
  });

  test('should feed tool errors back instead of throwing', () async {
    final replies = [
      toolCall('web_fetch', {'url': 'x'}),
      answer
    ];
    final history = <llama.Message>[];
    await runToolLoop(history, (_) async => replies.removeAt(0),
        (_, __) async => throw Exception('boom'));
    expect(history[1].content, contains('failed'));
  });

  test('should stop after max rounds when model keeps calling tools', () async {
    var calls = 0;
    final result = await runToolLoop([], (_) async {
      calls++;
      return toolCall('web_search', {'query': 'again'});
    }, (_, __) async => 'r');
    expect(calls, maxToolRounds);
    expect(result, contains('Stopped'));
  });

  test('should truncate oversized tool output', () async {
    final replies = [
      toolCall('web_fetch', {'url': 'x'}),
      answer
    ];
    final history = <llama.Message>[];
    await runToolLoop(history, (_) async => replies.removeAt(0),
        (_, __) async => 'a' * (maxToolResultChars * 2));
    expect(history[1].content.length, maxToolResultChars);
  });

  test('should call cloud web search with bearer key', () async {
    late http.Request seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'results': []}), 200);
    });
    final run = webToolRunner(client, 'k');
    expect(await run('web_search', {'query': 'q'}), '{"results":[]}');
    expect(seen.url.toString(), 'https://ollama.com/api/web_search');
    expect(seen.headers['Authorization'], 'Bearer k');
    expect(jsonDecode(seen.body)['query'], 'q');
  });
}

void marketToolTests() {
  group('market tools', () {
    late List<Uri> requested;
    late http.Client client;

    setUp(() {
      requested = [];
      client = MockClient((req) async {
        requested.add(req.url);
        return http.Response('[]', 200);
      });
    });

    test('should fetch price and candles with validated parameters', () async {
      final run = marketToolRunner(client);
      await run('crypto_price', {'symbol': 'btcusdt'});
      await run('crypto_candles',
          {'symbol': 'ETHUSDT', 'interval': '4h', 'limit': 9999});
      expect(requested[0].toString(),
          'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT');
      expect(requested[1].queryParameters,
          {'symbol': 'ETHUSDT', 'interval': '4h', 'limit': '100'});
    });

    test('should reject symbols that could alter the request', () async {
      final run = marketToolRunner(client);
      for (final bad in ['BTCUSDT&x=1', '../order', 'BTC', '']) {
        await expectLater(run('crypto_price', {'symbol': bad}),
            throwsA(isA<ArgumentError>()));
      }
      expect(requested, isEmpty);
    });

    test('should reject unknown intervals', () async {
      await expectLater(
          marketToolRunner(client)(
              'crypto_candles', {'symbol': 'BTCUSDT', 'interval': '7x'}),
          throwsA(isA<ArgumentError>()));
    });

    test('should expose no tool that can trade', () {
      final names = marketTools.map((t) => t.function!.name);
      expect(names, ['crypto_price', 'crypto_candles']);
    });

    test('should only run tools from enabled packs', () async {
      final none = buildToolSet(client);
      expect(none.tools, isEmpty);
      expect(await none.run('crypto_price', {'symbol': 'BTCUSDT'}),
          contains('not enabled'));
      final marketOnly = buildToolSet(client, market: true);
      expect(marketOnly.tools.length, marketTools.length);
      expect(await marketOnly.run('web_search', {'query': 'x'}),
          contains('not enabled'));
      expect(requested, isEmpty);
      final both = buildToolSet(client, webApiKey: 'k', market: true);
      expect(both.tools.length, webTools.length + marketTools.length);
    });
  });
}
