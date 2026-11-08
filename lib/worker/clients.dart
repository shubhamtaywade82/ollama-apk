import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;

import '../main.dart';

/// Every Cloud request goes here; `http://ollama.com` is upgraded so the
/// bearer key is never sent in clear text.
const cloudOrigin = 'https://ollama.com';

bool isCloudHost(String? h) {
  if (h == null) return false;
  final normalized =
      (h.startsWith('https://') || h.startsWith('http://')) ? h : 'https://$h';
  return h == 'ollama.com' ||
      h == 'https://ollama.com' ||
      Uri.tryParse(normalized)?.host == 'ollama.com';
}

final httpClient = http.Client();

const _secureStorage = FlutterSecureStorage();
const _cloudKeyName = 'ollamaCloudApiKey';

/// In-memory copy of the Keystore-backed Cloud key, so the synchronous
/// client getter can read it. Loaded once at startup.
String? cloudApiKey;

/// Loads the Cloud key, moving any key left in plain preferences by older
/// versions into secure storage.
Future<void> loadCloudApiKey(SharedPreferences prefs) async {
  final legacy = prefs.getString('apiKey');
  if (legacy != null) {
    if (legacy.isNotEmpty) {
      await _secureStorage.write(key: _cloudKeyName, value: legacy);
    }
    await prefs.remove('apiKey');
  }
  cloudApiKey = await _secureStorage.read(key: _cloudKeyName);
}

Future<void> saveCloudApiKey(String key) async {
  if (key.isEmpty) {
    await _secureStorage.delete(key: _cloudKeyName);
    cloudApiKey = null;
    return;
  }
  await _secureStorage.write(key: _cloudKeyName, value: key);
  cloudApiKey = key;
}

/// Custom host headers, plus the Cloud key only when the host is Cloud.
Map<String, String> ollamaClientHeaders() {
  final headers = Map<String, String>.from(
      (jsonDecode(prefs!.getString('hostHeaders') ?? '{}') as Map)
          .cast<String, String>());
  final apiKey = cloudApiKey;
  // The Cloud key must never reach a local or third-party host.
  if (isCloudHost(host) && apiKey != null && apiKey.isNotEmpty) {
    headers['Authorization'] = 'Bearer $apiKey';
  }
  return headers;
}

llama.OllamaClient get ollamaClient {
  final baseUrl = isCloudHost(host) ? '$cloudOrigin/api' : '${host ?? ''}/api';
  return llama.OllamaClient(
      headers: ollamaClientHeaders(), baseUrl: baseUrl, client: httpClient);
}
