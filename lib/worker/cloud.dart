import 'dart:convert';

import 'package:http/http.dart' as http;

const cloudBaseUrl = 'https://ollama.com';
const usageRanges = ['24h', '7d', '30d'];

class CloudApiException implements Exception {
  final int status;
  final String path;
  final String body;

  const CloudApiException(this.status, this.path, this.body);

  bool get isUnauthorized => status == 401 || status == 403;

  @override
  String toString() => 'Ollama Cloud $path failed ($status): $body';
}

class UsageMetrics {
  final int requestCount;
  final double usageUsd;
  final int inputTokens;
  final int cachedInputTokens;
  final int outputTokens;

  const UsageMetrics(
      {required this.requestCount,
      this.usageUsd = 0,
      this.inputTokens = 0,
      this.cachedInputTokens = 0,
      this.outputTokens = 0});

  factory UsageMetrics.fromJson(Map<String, dynamic> json) => UsageMetrics(
      requestCount: (json['request_count'] as num?)?.toInt() ?? 0,
      usageUsd: (json['usage_usd'] as num?)?.toDouble() ?? 0,
      inputTokens: (json['input_tokens'] as num?)?.toInt() ?? 0,
      cachedInputTokens: (json['cached_input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (json['output_tokens'] as num?)?.toInt() ?? 0);

  int get totalTokens => inputTokens + outputTokens;
}

class ModelUsage {
  final String model;
  final UsageMetrics metrics;

  const ModelUsage(this.model, this.metrics);
}

class UsageBucket {
  final DateTime from;
  final bool isPartial;
  final UsageMetrics metrics;

  const UsageBucket(this.from, this.isPartial, this.metrics);
}

class UsageReport {
  final String range;
  final UsageMetrics totals;
  final List<ModelUsage> byModel;
  final List<UsageBucket> buckets;

  const UsageReport(this.range, this.totals, this.byModel, this.buckets);

  factory UsageReport.fromJson(Map<String, dynamic> json) {
    final totals = (json['totals'] as Map).cast<String, dynamic>();
    return UsageReport(
        json['range'] as String,
        UsageMetrics.fromJson(totals),
        _groups(totals),
        ((json['buckets'] as List?) ?? []).map((raw) {
          final bucket = (raw as Map).cast<String, dynamic>();
          return UsageBucket(DateTime.parse(bucket['from'] as String),
              bucket['partial'] == true, UsageMetrics.fromJson(bucket));
        }).toList());
  }

  static List<ModelUsage> _groups(Map<String, dynamic> totals) =>
      ((totals['groups'] as List?) ?? []).map((raw) {
        final group = (raw as Map).cast<String, dynamic>();
        return ModelUsage(
            group['model'] as String, UsageMetrics.fromJson(group));
      }).toList();
}

/// Remaining share of a rolling allowance (legacy session/weekly plans).
class PercentLimit {
  final double remainingPercent;
  final DateTime resetsAt;

  const PercentLimit(this.remainingPercent, this.resetsAt);
}

/// Included credits come as a USD allowance (current plans) or as
/// session/weekly percentage limits (legacy plans); exactly one is set.
class CloudBalance {
  final double purchasedUsd;
  final double? includedUsd;
  final double? allowanceUsd;
  final PercentLimit? session;
  final PercentLimit? weekly;

  const CloudBalance(
      {required this.purchasedUsd,
      this.includedUsd,
      this.allowanceUsd,
      this.session,
      this.weekly});

  bool get isLegacy => session != null;

  factory CloudBalance.fromJson(Map<String, dynamic> json) {
    final included = (json['included'] as Map).cast<String, dynamic>();
    final purchased =
        ((json['purchased'] as Map?)?['balance_usd'] as num?)?.toDouble() ?? 0;
    if (included.containsKey('session')) {
      return CloudBalance(
          purchasedUsd: purchased,
          session: _limit(included['session']),
          weekly: _limit(included['weekly']));
    }
    return CloudBalance(
        purchasedUsd: purchased,
        includedUsd: (included['balance_usd'] as num).toDouble(),
        allowanceUsd: (included['allowance_usd'] as num).toDouble());
  }

  static PercentLimit _limit(dynamic raw) {
    final limit = (raw as Map).cast<String, dynamic>();
    return PercentLimit((limit['remaining_percent'] as num).toDouble(),
        DateTime.parse(limit['resets_at'] as String));
  }
}

Future<Map<String, dynamic>> _getJson(
    http.Client client, String apiKey, String path) async {
  final response = await client.get(Uri.parse('$cloudBaseUrl$path'),
      headers: {'Authorization': 'Bearer $apiKey'});
  if (response.statusCode != 200) {
    throw CloudApiException(response.statusCode, path, response.body);
  }
  return (jsonDecode(response.body) as Map).cast<String, dynamic>();
}

Future<UsageReport> fetchUsage(http.Client client, String apiKey,
        {String range = '7d'}) async =>
    UsageReport.fromJson(await _getJson(
        client, apiKey, '/api/usage?range=$range&group_by=model'));

Future<CloudBalance> fetchBalance(http.Client client, String apiKey) async =>
    CloudBalance.fromJson(await _getJson(client, apiKey, '/api/balance'));

Future<Map<String, dynamic>> _postJson(http.Client client, String apiKey,
    String path, Map<String, dynamic> body) async {
  final response = await client.post(Uri.parse('$cloudBaseUrl$path'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json'
      },
      body: jsonEncode(body));
  if (response.statusCode != 200) {
    throw CloudApiException(response.statusCode, path, response.body);
  }
  return (jsonDecode(response.body) as Map).cast<String, dynamic>();
}

/// Ollama's hosted web search; returns `{results: [{title, url, content}]}`.
Future<Map<String, dynamic>> webSearch(
        http.Client client, String apiKey, String query,
        {int maxResults = 5}) =>
    _postJson(client, apiKey, '/api/web_search',
        {'query': query, 'max_results': maxResults});

/// Ollama's hosted page fetch; returns `{title, content, links}`.
Future<Map<String, dynamic>> webFetch(
        http.Client client, String apiKey, String url) =>
    _postJson(client, apiKey, '/api/web_fetch', {'url': url});
