import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;

import '../main.dart';

bool isCloudHost(String? h) {
  if (h == null) return false;
  final normalized = (h.startsWith('https://') || h.startsWith('http://'))
      ? h
      : 'https://$h';
  return h == 'ollama.com' ||
      h == 'https://ollama.com' ||
      Uri.tryParse(normalized)?.host == 'ollama.com';
}

final httpClient = http.Client();
llama.OllamaClient get ollamaClient {
  final headers = Map<String, String>.from(
      (jsonDecode(prefs!.getString('hostHeaders') ?? '{}') as Map)
          .cast<String, String>());
  final apiKey = prefs!.getString('apiKey');
  if (apiKey != null && apiKey.isNotEmpty) {
    headers['Authorization'] = 'Bearer $apiKey';
  }
  final baseUrl = isCloudHost(host) ? 'https://ollama.com/api' : '${host ?? ''}/api';
  return llama.OllamaClient(
      headers: headers, baseUrl: baseUrl, client: httpClient);
}
