import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;
import 'package:shared_preferences/shared_preferences.dart';

const mcpProtocolVersion = '2025-06-18';
const _supportedProtocolVersions = {'2025-06-18', '2025-03-26'};

// A remote server controls these sizes; cap them so a hostile or broken
// server cannot exhaust memory or flood the model's tool list.
const maxMcpResponseBytes = 1024 * 1024;
const maxMcpToolsPerServer = 64;
const _sessionHeader = 'mcp-session-id';
const _requestTimeout = Duration(seconds: 20);

class McpServer {
  final String name;
  final String url;
  final String token;

  const McpServer({required this.name, required this.url, this.token = ''});

  Map<String, String> toJson() => {'name': name, 'url': url, 'token': token};

  factory McpServer.fromJson(Map<String, dynamic> json) => McpServer(
      name: json['name'] as String,
      url: json['url'] as String,
      token: (json['token'] as String?) ?? '');
}

class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpTool(this.name, this.description, this.inputSchema);
}

class McpException implements Exception {
  final String message;

  const McpException(this.message);

  @override
  String toString() => 'MCP: $message';
}

/// Minimal MCP client for the Streamable HTTP transport: JSON-RPC over POST,
/// answered either as plain JSON or as a server-sent event stream.
class McpClient {
  final http.Client http_;
  final McpServer server;
  String? _sessionId;
  int _nextId = 1;

  McpClient(this.http_, this.server);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'MCP-Protocol-Version': mcpProtocolVersion,
        if (server.token.isNotEmpty) 'Authorization': 'Bearer ${server.token}',
        _sessionHeader: ?_sessionId,
      };

  Future<http.Response> _post(Map<String, dynamic> body) => http_
      .post(Uri.parse(server.url), headers: _headers, body: jsonEncode(body))
      .timeout(_requestTimeout);

  Future<Map<String, dynamic>> _request(
      String method, Map<String, dynamic> params) async {
    final id = _nextId++;
    final response = await _post(
        {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    if (response.statusCode != 200) {
      throw McpException('$method failed (${response.statusCode})');
    }
    _sessionId = response.headers[_sessionHeader] ?? _sessionId;
    if (response.bodyBytes.length > maxMcpResponseBytes) {
      throw McpException('$method response exceeds $maxMcpResponseBytes bytes');
    }
    final message = _findResponse(response, id);
    final error = message['error'];
    if (error is Map) throw McpException('$method: ${error['message']}');
    return (message['result'] as Map? ?? {}).cast<String, dynamic>();
  }

  Future<void> initialize() async {
    final result = await _request('initialize', {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': {},
      'clientInfo': {'name': 'ollama-apk', 'version': '1.0.0'},
    });
    final negotiated = result['protocolVersion'];
    if (!_supportedProtocolVersions.contains(negotiated)) {
      throw McpException('unsupported protocol version $negotiated');
    }
    await _post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
  }

  Future<List<McpTool>> listTools() async {
    final result = await _request('tools/list', {});
    return ((result['tools'] as List?) ?? [])
        .take(maxMcpToolsPerServer)
        .map((raw) {
      final tool = (raw as Map).cast<String, dynamic>();
      return McpTool(
          tool['name'] as String,
          (tool['description'] as String?) ?? '',
          ((tool['inputSchema'] as Map?) ?? {'type': 'object'})
              .cast<String, dynamic>());
    }).toList();
  }

  /// Text content of the tool result; non-text parts are summarized.
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    final result =
        await _request('tools/call', {'name': name, 'arguments': arguments});
    final parts = ((result['content'] as List?) ?? []).map((raw) {
      final part = (raw as Map).cast<String, dynamic>();
      return part['type'] == 'text'
          ? '${part['text']}'
          : '[${part['type']} content omitted]';
    }).join('\n');
    return result['isError'] == true ? 'Tool error: $parts' : parts;
  }
}

/// The JSON-RPC response with [id], from a JSON body or an SSE stream.
Map<String, dynamic> _findResponse(http.Response response, int id) {
  final type = response.headers['content-type'] ?? '';
  final candidates = type.contains('text/event-stream')
      ? _sseData(response.body)
      : [response.body];
  for (final data in candidates) {
    final decoded = jsonDecode(data);
    final messages = decoded is List ? decoded : [decoded];
    for (final message in messages) {
      if (message is Map && message['id'] == id) {
        return message.cast<String, dynamic>();
      }
    }
  }
  throw const McpException('no response for request');
}

Iterable<String> _sseData(String body) sync* {
  final buffer = StringBuffer();
  for (final line in const LineSplitter().convert(body)) {
    if (line.startsWith('data:')) {
      buffer.write(line.substring(5).trimLeft());
    } else if (line.isEmpty && buffer.isNotEmpty) {
      yield buffer.toString();
      buffer.clear();
    }
  }
  if (buffer.isNotEmpty) yield buffer.toString();
}

/// Ollama tool names must be simple identifiers; MCP names are namespaced
/// by server so two servers can expose a tool with the same name.
///
/// Slugs alone collide ('a b' and 'a_b'), so a short stable hash of the
/// exact server URL and tool name is appended.
String mcpToolName(McpServer server, McpTool tool) {
  final readable = '${_slug(server.name)}_${_slug(tool.name)}';
  final clipped = readable.length > 40 ? readable.substring(0, 40) : readable;
  return 'mcp_${clipped}_${_fnv1a('${server.url}\n${tool.name}')}';
}

/// 32-bit FNV-1a as 8 hex digits: stable across runs, unlike hashCode.
String _fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

const _allowedToolsKey = 'mcpAllowedTools';

String _toolKey(McpServer server, String toolName) =>
    '${server.url}\n$toolName';

/// Tools the user has switched on. New servers' tools start off: adding a
/// server is not consent for every tool it exposes.
bool isMcpToolAllowed(SharedPreferences prefs, McpServer server, String tool) =>
    (prefs.getStringList(_allowedToolsKey) ?? [])
        .contains(_toolKey(server, tool));

Future<void> setMcpToolAllowed(SharedPreferences prefs, McpServer server,
    String tool, bool allowed) async {
  final keys = {...prefs.getStringList(_allowedToolsKey) ?? <String>[]};
  final key = _toolKey(server, tool);
  allowed ? keys.add(key) : keys.remove(key);
  await prefs.setStringList(_allowedToolsKey, keys.toList());
}

String _slug(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

typedef McpConnection = ({McpClient client, List<McpTool> tools});

llama.ToolDefinition toOllamaTool(McpServer server, McpTool tool) =>
    llama.ToolDefinition(
    function: llama.ToolFunction(
        name: mcpToolName(server, tool),
        description: '[${server.name}] ${tool.description}',
        parameters: tool.inputSchema));

const _serversKey = 'mcpServers';

/// Saved MCP servers. Kept in secure storage because entries carry tokens.
List<McpServer> mcpServers = [];

final _connections = <String, McpConnection>{};

/// Last connection error per server URL, for the settings screen.
final mcpErrors = <String, String>{};

Future<void> loadMcpServers(FlutterSecureStorage storage) async {
  final raw = await storage.read(key: _serversKey);
  mcpServers = raw == null
      ? []
      : (jsonDecode(raw) as List)
          .map((e) => McpServer.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
}

Future<void> saveMcpServers(
    FlutterSecureStorage storage, List<McpServer> servers) async {
  mcpServers = List.of(servers);
  _connections.clear();
  mcpErrors.clear();
  await storage.write(
      key: _serversKey,
      value: jsonEncode(servers.map((s) => s.toJson()).toList()));
}

/// Connections to every saved server, reusing ones already open. A server
/// that fails is skipped (and its error recorded) so one bad server does
/// not take the others down.
Future<List<McpConnection>> connectMcpServers(http.Client client) async {
  final connected = <McpConnection>[];
  for (final server in mcpServers) {
    final cached = _connections[server.url];
    if (cached != null) {
      connected.add(cached);
      continue;
    }
    try {
      final mcp = McpClient(client, server);
      await mcp.initialize();
      final connection = (client: mcp, tools: await mcp.listTools());
      _connections[server.url] = connection;
      mcpErrors.remove(server.url);
      connected.add(connection);
    } catch (e) {
      mcpErrors[server.url] = '$e';
    }
  }
  return connected;
}

/// [connections] reduced to the tools the user has switched on; servers
/// with none left are dropped.
List<McpConnection> allowedMcpConnections(
        SharedPreferences prefs, List<McpConnection> connections) =>
    [
      for (final c in connections)
        if (c.tools
            .any((t) => isMcpToolAllowed(prefs, c.client.server, t.name)))
          (
            client: c.client,
            tools: c.tools
                .where((t) => isMcpToolAllowed(prefs, c.client.server, t.name))
                .toList()
          )
    ];
