import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_app/worker/agent.dart';
import 'package:ollama_app/worker/mcp.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  hardeningTests();
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

    final name = set.tools.single.function.name;
    expect(name, startsWith('mcp_notes_search_notes_'));
    expect(await set.run(name, {'q': 'eggs'}), startsWith('found: eggs'));
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

MockClient replying(Map<String, dynamic> result, {String padding = ''}) =>
    MockClient((req) async {
      final id = jsonDecode(req.body)['id'];
      if (id == null) return http.Response('', 202);
      return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}) + padding,
          200);
    });

void hardeningTests() {
  test('should reject a server negotiating an unsupported protocol', () {
    final client =
        McpClient(replying({'protocolVersion': '1999-01-01'}), server);
    expect(client.initialize(), throwsA(isA<McpException>()));
  });

  test('should reject oversized responses before parsing', () {
    final client = McpClient(
        replying({'tools': []}, padding: ' ' * (maxMcpResponseBytes + 1)),
        server);
    expect(client.listTools(), throwsA(isA<McpException>()));
  });

  test('should keep at most maxMcpToolsPerServer tools', () async {
    final client = McpClient(
        replying({
          'tools': [
            for (var i = 0; i < 100; i++) {'name': 't$i'}
          ]
        }),
        server);
    expect((await client.listTools()).length, maxMcpToolsPerServer);
  });

  test('should give distinct names to tools whose slugs collide', () {
    const a = McpTool('a b', '', {});
    const b = McpTool('a_b', '', {});
    expect(mcpToolName(server, a), isNot(mcpToolName(server, b)));
    expect(mcpToolName(server, a), mcpToolName(server, a));
  });

  test('should expose only tools the user switched on', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final mcp = McpClient(fakeMcp([]), server);
    await mcp.initialize();
    final connection = (client: mcp, tools: await mcp.listTools());

    expect(allowedMcpConnections(prefs, [connection]), isEmpty);
    await setMcpToolAllowed(prefs, server, 'search notes', true);
    expect(allowedMcpConnections(prefs, [connection]).single.tools.single.name,
        'search notes');
    await setMcpToolAllowed(prefs, server, 'search notes', false);
    expect(allowedMcpConnections(prefs, [connection]), isEmpty);
  });
}
