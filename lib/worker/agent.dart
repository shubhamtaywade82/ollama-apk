import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;

import 'cloud.dart';

const maxToolRounds = 5;

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
    for (final call in calls) {
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

ToolRunner webToolRunner(http.Client client, String apiKey) =>
    (name, arguments) async {
      switch (name) {
        case 'web_search':
          return jsonEncode(
              await webSearch(client, apiKey, '${arguments['query']}'));
        case 'web_fetch':
          return jsonEncode(
              await webFetch(client, apiKey, '${arguments['url']}'));
        default:
          return 'Unknown tool $name';
      }
    };
