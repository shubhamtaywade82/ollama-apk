import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/l10n/gen/app_localizations.dart';
import 'package:ollama_app/settings/cloud.dart';
import 'package:ollama_app/worker/clients.dart';
import 'package:ollama_app/worker/cloud.dart';

Future<void> pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child))));

void main() {
  testWidgets('should explain how to add a key when none is saved',
      (tester) async {
    cloudApiKey = null;
    await tester.pumpWidget(const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ScreenSettingsCloud()));
    expect(find.textContaining('API key under Hosts'), findsOneWidget);
  });

  testWidgets('should show allowance and purchased credit', (tester) async {
    await pump(
        tester,
        const BalanceCard(
            balance: CloudBalance(
                purchasedUsd: 2, includedUsd: 3.5, allowanceUsd: 10)));
    expect(find.textContaining('\$3.50 / \$10.00'), findsOneWidget);
    expect(find.textContaining('\$2.00'), findsOneWidget);
  });

  testWidgets('should show legacy session and weekly percentages',
      (tester) async {
    await pump(
        tester,
        BalanceCard(
            balance: CloudBalance(
                purchasedUsd: 0,
                session: PercentLimit(80, DateTime(2026)),
                weekly: PercentLimit(40, DateTime(2026)))));
    expect(find.textContaining('80%'), findsOneWidget);
    expect(find.textContaining('40%'), findsOneWidget);
  });

  testWidgets('should list per-model usage', (tester) async {
    await pump(
        tester,
        UsageCard(
            usage: UsageReport.fromJson(const {
          'range': '7d',
          'totals': {
            'request_count': 3,
            'groups': [
              {'model': 'gemma4:cloud', 'request_count': 3, 'usage_usd': 0.01}
            ]
          },
          'buckets': []
        })));
    expect(find.text('gemma4:cloud'), findsOneWidget);
    expect(find.textContaining('Requests: 3'), findsOneWidget);
  });
}
