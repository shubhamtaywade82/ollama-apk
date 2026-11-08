import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show TargetPlatform;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show host, prefs;
import 'clients.dart' show cloudApiKey, cloudOrigin, httpClient, isCloudHost;
import 'package:ollama_dart/ollama_dart.dart' show OllamaClientException;

const _hostsKey = 'hosts';
const _pingTimeout = Duration(seconds: 5);

class OllamaHost {
  final String name;
  final String url;

  const OllamaHost({required this.name, required this.url});

  bool get isCloud => isCloudHost(url);

  /// Keys are only ever sent to Ollama Cloud over HTTPS.
  Map<String, String> get headers => isCloud && (cloudApiKey ?? '').isNotEmpty
      ? {'Authorization': 'Bearer $cloudApiKey'}
      : {};

  Map<String, String> toJson() => {'name': name, 'url': url};

  factory OllamaHost.fromJson(Map<String, dynamic> json) =>
      OllamaHost(name: json['name'] as String, url: json['url'] as String);
}

class HostHealth {
  final bool isUp;
  final Duration? latency;
  final String? error;

  const HostHealth.up(Duration this.latency)
      : isUp = true,
        error = null;
  const HostHealth.down(String this.error)
      : isUp = false,
        latency = null;
}

String normalizeHostUrl(String raw) {
  final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
  return isCloudHost(trimmed) ? cloudOrigin : trimmed;
}

/// Saved hosts in priority order. Migrates the legacy single `host` pref.
List<OllamaHost> loadHosts(SharedPreferences prefs) {
  final raw = prefs.getString(_hostsKey);
  if (raw != null) {
    return (jsonDecode(raw) as List)
        .map((e) => OllamaHost.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }
  final legacy = prefs.getString('host');
  if (legacy == null) return [];
  return [
    OllamaHost(
        name: Uri.tryParse(legacy)?.host ?? legacy,
        url: normalizeHostUrl(legacy))
  ];
}

Future<void> saveHosts(SharedPreferences prefs, List<OllamaHost> hosts) => prefs
    .setString(_hostsKey, jsonEncode(hosts.map((h) => h.toJson()).toList()));

/// Adds the host, or replaces the one with the same URL, keeping its position.
Future<List<OllamaHost>> upsertHost(
    SharedPreferences prefs, OllamaHost host) async {
  final hosts = loadHosts(prefs);
  final index = hosts.indexWhere((h) => h.url == host.url);
  if (index >= 0) {
    hosts[index] = host;
  } else {
    hosts.add(host);
  }
  await saveHosts(prefs, hosts);
  return hosts;
}

Future<List<OllamaHost>> removeHost(SharedPreferences prefs, String url) async {
  final hosts = loadHosts(prefs)..removeWhere((h) => h.url == url);
  await saveHosts(prefs, hosts);
  return hosts;
}

/// Points the `host` pref (read by the Ollama client) at [host].
Future<void> activateHost(SharedPreferences prefs, OllamaHost host) async {
  await prefs.setString('host', host.url);
}

/// Local Ollama answers "Ollama is running" at `/`; Cloud has no such root
/// route, so its key is verified against `/api/tags` instead.
///
/// [headers] overrides the saved credentials, so a key can be tested before
/// it is saved.
Future<HostHealth> pingHost(OllamaHost host, http.Client client,
    {Duration timeout = _pingTimeout, Map<String, String>? headers}) async {
  final uri = Uri.parse(host.isCloud ? '$cloudOrigin/api/tags' : host.url);
  final stopwatch = Stopwatch()..start();
  try {
    final response = await client
        .get(uri, headers: headers ?? host.headers)
        .timeout(timeout);
    if (response.statusCode == 401 || response.statusCode == 403) {
      return const HostHealth.down('unauthorized');
    }
    final healthy = host.isCloud
        ? response.statusCode == 200
        : response.statusCode == 200 && response.body.contains('Ollama');
    return healthy
        ? HostHealth.up(stopwatch.elapsed)
        : HostHealth.down('unexpected response ${response.statusCode}');
  } catch (e) {
    return HostHealth.down(e.toString());
  }
}

/// First host in priority order that is healthy, skipping [skipUrl]
/// (the host that just failed). Null when every host is down.
/// With [sameTrustAs], only hosts on the same side of the local/Cloud
/// boundary qualify: a failed local server must never silently send the
/// conversation to Ollama Cloud, and vice versa.
Future<OllamaHost?> firstHealthyHost(List<OllamaHost> hosts, http.Client client,
    {String? skipUrl, String? sameTrustAs}) async {
  for (final host in hosts) {
    if (host.url == skipUrl) continue;
    if (sameTrustAs != null && host.isCloud != isCloudHost(sameTrustAs)) {
      continue;
    }
    if ((await pingHost(host, client)).isUp) return host;
  }
  return null;
}

/// Switches the active host after [failedUrl] stopped answering.
/// Returns the new host, or null if nothing else is reachable.
Future<OllamaHost?> failoverFrom(
    SharedPreferences prefs, http.Client client, String failedUrl) async {
  final next = await firstHealthyHost(loadHosts(prefs), client,
      skipUrl: failedUrl, sameTrustAs: failedUrl);
  if (next != null) await activateHost(prefs, next);
  return next;
}

/// True for errors another host could plausibly avoid; false for client
/// errors (bad model, bad key) that would repeat on every host.
bool isHostFailure(Object error) {
  if (error is OllamaClientException) {
    final code = error.code;
    return code == null || code >= 500;
  }
  // Only transport failures; a local bug must not switch the saved host.
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;
}

/// Chat-time failover: switch the app to the next healthy saved host.
Future<bool> failoverActiveHost(Object error) async {
  final current = host;
  if (current == null || prefs == null || !isHostFailure(error)) return false;
  final next = await failoverFrom(prefs!, httpClient, current);
  if (next == null) return false;
  host = next.url;
  return true;
}

/// On a phone `localhost` is the phone itself, never the computer running
/// Ollama, so saving it is almost always a mistake.
bool isLoopbackOnPhone(String url, TargetPlatform platform) {
  if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
    return false;
  }
  final host = Uri.tryParse(normalizeHostUrl(url))?.host ?? '';
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}
