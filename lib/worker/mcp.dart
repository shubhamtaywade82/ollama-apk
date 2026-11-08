import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;

const mcpProtocolVersion = '2025-06-18';
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
        if (_sessionId != null) _sessionHeader: _sessionId!,
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
    final message = _findResponse(response, id);
    final error = message['error'];
    if (error is Map) throw McpException('$method: ${error['message']}');
    return (message['result'] as Map? ?? {}).cast<String, dynamic>();
  }

  Future<void> initialize() async {
    await _request('initialize', {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': {},
      'clientInfo': {'name': 'ollama-apk', 'version': '1.0.0'},
    });
    await _post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
  }

  Future<List<McpTool>> listTools() async {
    final result = await _request('tools/list', {});
    return ((result['tools'] as List?) ?? []).map((raw) {
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
String mcpToolName(McpServer server, McpTool tool) =>
    'mcp_${_slug(server.name)}_${_slug(tool.name)}';

String _slug(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

typedef McpConnection = ({McpClient client, List<McpTool> tools});

llama.Tool toOllamaTool(McpServer server, McpTool tool) => llama.Tool(
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
