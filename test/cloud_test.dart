import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_app/worker/cloud.dart';

const usageJson = {
  'range': '7d',
  'totals': {
    'request_count': 12,
    'usage_usd': 0.5,
    'input_tokens': 1000,
    'output_tokens': 200,
    'groups': [
      {'model': 'gemma4:cloud', 'request_count': 12, 'usage_usd': 0.5}
    ]
  },
  'buckets': [
    {'from': '2026-11-01T00:00:00Z', 'request_count': 5, 'partial': true}
  ]
};

void main() {
  test('should parse usage totals, per-model groups and buckets', () {
    final report = UsageReport.fromJson(usageJson);
    expect(report.totals.requestCount, 12);
    expect(report.totals.totalTokens, 1200);
    expect(report.byModel.single.model, 'gemma4:cloud');
    expect(report.buckets.single.isPartial, isTrue);
  });

  test('should parse allowance balance', () {
    final balance = CloudBalance.fromJson({
      'included': {
        'balance_usd': 3.5,
        'allowance_usd': 10,
        'period': {'from': 'a', 'until': 'b'}
      },
      'purchased': {'balance_usd': 2}
    });
    expect(balance.isLegacy, isFalse);
    expect(balance.includedUsd, 3.5);
    expect(balance.allowanceUsd, 10);
    expect(balance.purchasedUsd, 2);
  });

  test('should parse legacy session and weekly balance', () {
    final balance = CloudBalance.fromJson({
      'included': {
        'session': {
          'remaining_percent': 80,
          'resets_at': '2026-11-08T10:00:00Z'
        },
        'weekly': {'remaining_percent': 40, 'resets_at': '2026-11-14T00:00:00Z'}
      },
      'purchased': {'balance_usd': 0}
    });
    expect(balance.isLegacy, isTrue);
    expect(balance.weekly!.remainingPercent, 40);
  });

  test('should send bearer key and raise typed error on 401', () async {
    String? auth;
    final ok = MockClient((req) async {
      auth = req.headers['Authorization'];
      expect(req.url.path, '/api/usage');
      expect(req.url.queryParameters['group_by'], 'model');
      return http.Response(jsonEncode(usageJson), 200);
    });
    await fetchUsage(ok, 'secret', range: '24h');
    expect(auth, 'Bearer secret');

    final denied = MockClient((_) async => http.Response('nope', 401));
    expect(
        fetchBalance(denied, 'bad'),
        throwsA(isA<CloudApiException>()
            .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)));
  });
}
