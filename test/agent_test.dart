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
