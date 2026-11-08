import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_app/worker/agent.dart';
import 'package:ollama_app/worker/mcp.dart';

const server =
    McpServer(name: 'Notes', url: 'https://mcp.example/mcp', token: 'secret');

/// A fake MCP server. Answers as SSE when [sse] is true, plain JSON otherwise.
MockClient fakeMcp(List<Map<String, dynamic>> seen, {bool sse = false}) =>
    MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      seen.add({...body, '_headers': req.headers});
      final id = body['id'];
      if (id == null) return http.Response('', 202);
      final result = switch (body['method']) {
        'initialize' => {'protocolVersion': mcpProtocolVersion},
        'tools/list' => {
            'tools': [
              {
                'name': 'search notes',
                'description': 'Find notes',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'q': {'type': 'string'}
                  }
                }
              }
            ]
          },
        'tools/call' => {
            'content': [
              {
                'type': 'text',
                'text': 'found: ${body['params']['arguments']['q']}'
              },
              {'type': 'image', 'data': 'AAAA'}
            ]
          },
        _ => null,
      };
      final reply = jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});
      return sse
          ? http.Response('event: message\ndata: $reply\n\n', 200,
              headers: {'content-type': 'text/event-stream'})
          : http.Response(reply, 200, headers: {
              'content-type': 'application/json',
              'mcp-session-id': 'sess-1'
            });
    });

void main() {
  test('should initialize, list and call tools over plain JSON', () async {
    final seen = <Map<String, dynamic>>[];
    final client = McpClient(fakeMcp(seen), server);
    await client.initialize();
    final tools = await client.listTools();
    final result = await client.callTool('search notes', {'q': 'milk'});

    expect(tools.single.name, 'search notes');
    expect(result, 'found: milk\n[image content omitted]');
    expect(seen.map((m) => m['method']), [
      'initialize',
      'notifications/initialized',
      'tools/list',
      'tools/call'
    ]);
    final firstHeaders = seen.first['_headers'] as Map<String, String>;
    final lastHeaders = seen.last['_headers'] as Map<String, String>;
    expect(firstHeaders['Authorization'], 'Bearer secret');
    expect(firstHeaders.containsKey('mcp-session-id'), isFalse);
    expect(lastHeaders['mcp-session-id'], 'sess-1');
  });

  test('should read responses delivered as server-sent events', () async {
    final client = McpClient(fakeMcp([], sse: true), server);
    await client.initialize();
    expect((await client.listTools()).single.description, 'Find notes');
  });

  test('should surface JSON-RPC errors as McpException', () async {
    final client = McpClient(
        MockClient((req) async => http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': jsonDecode(req.body)['id'],
              'error': {'code': -32601, 'message': 'nope'}
            }),
            200)),
        server);
    expect(client.listTools(), throwsA(isA<McpException>()));
  });

  test('should namespace tool names and route calls to the right server',
      () async {
    final mcp = McpClient(fakeMcp([]), server);
    await mcp.initialize();
    final connection = (client: mcp, tools: await mcp.listTools());
    final set = buildToolSet(http.Client(), mcp: [connection]);

    expect(set.tools.single.function!.name, 'mcp_notes_search_notes');
    expect(await set.run('mcp_notes_search_notes', {'q': 'eggs'}),
        startsWith('found: eggs'));
    expect(await set.run('mcp_other_tool', {}), contains('not enabled'));
  });

  test('should persist servers with tokens in secure storage', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    await saveMcpServers(storage, [server]);
    mcpServers = [];
    await loadMcpServers(storage);
    expect(mcpServers.single.token, 'secret');
  });

  test('should skip a failing server and record its error', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const broken = McpServer(name: 'Down', url: 'https://down.example/mcp');
    await saveMcpServers(const FlutterSecureStorage(), [broken, server]);
    final healthy = fakeMcp([]);
    final client = MockClient((req) async => req.url.host == 'down.example'
        ? http.Response('bad gateway', 502)
        : await healthy.post(req.url, headers: req.headers, body: req.body));
    final connections = await connectMcpServers(client);
    expect(connections.single.client.server.name, 'Notes');
    expect(mcpErrors[broken.url], contains('502'));
  });
}
