import 'package:flutter/material.dart';

import '../worker/clients.dart';
import '../worker/cloud.dart';

import 'package:hearth/l10n/gen/app_localizations.dart';

class ScreenSettingsCloud extends StatefulWidget {
  const ScreenSettingsCloud({super.key});

  @override
  State<ScreenSettingsCloud> createState() => _ScreenSettingsCloudState();
}

class _ScreenSettingsCloudState extends State<ScreenSettingsCloud> {
  String range = '7d';
  Future<(UsageReport, CloudBalance)>? data;

  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    final key = cloudApiKey;
    if (key == null) return;
    setState(() {
      data = (
        fetchUsage(httpClient, key, range: range),
        fetchBalance(httpClient, key)
      ).wait;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitleCloud), actions: [
        IconButton(
            tooltip: l10n.hostsRefresh,
            onPressed: load,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      body: cloudApiKey == null
          ? Center(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.cloudNoKey, textAlign: TextAlign.center)))
          : FutureBuilder(future: data, builder: body),
    );
  }

  Widget body(
      BuildContext context, AsyncSnapshot<(UsageReport, CloudBalance)> snap) {
    if (snap.hasError) return Center(child: Text(describeError(snap.error!)));
    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
    final (usage, balance) = snap.data!;
    return ListView(padding: const EdgeInsets.all(16), children: [
      BalanceCard(balance: balance),
      const SizedBox(height: 16),
      SegmentedButton<String>(
          segments: [
            for (final r in usageRanges) ButtonSegment(value: r, label: Text(r))
          ],
          selected: {
            range
          },
          onSelectionChanged: (selection) {
            range = selection.first;
            load();
          }),
      const SizedBox(height: 16),
      UsageCard(usage: usage),
    ]);
  }

  String describeError(Object error) {
    final l10n = AppLocalizations.of(context)!;
    if (error is CloudApiException && error.isUnauthorized) {
      return l10n.cloudUnauthorized;
    }
    return error.toString();
  }
}

String usd(double value, [int digits = 2]) =>
    '\$${value.toStringAsFixed(digits)}';

class BalanceCard extends StatelessWidget {
  final CloudBalance balance;

  const BalanceCard({super.key, required this.balance});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.cloudBalance,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (balance.isLegacy) ...[
                percentMeter(l10n.cloudSession, balance.session!),
                percentMeter(l10n.cloudWeekly, balance.weekly!),
              ] else
                allowanceMeter(l10n.cloudIncluded),
              Text('${l10n.cloudPurchased}: ${usd(balance.purchasedUsd)}'),
            ])));
  }

  Widget allowanceMeter(String label) {
    final allowance = balance.allowanceUsd!;
    final left = balance.includedUsd!;
    return meter('$label  ${usd(left)} / ${usd(allowance)}',
        allowance == 0 ? 0 : left / allowance);
  }

  Widget percentMeter(String label, PercentLimit limit) => meter(
      '$label  ${limit.remainingPercent.toStringAsFixed(0)}%',
      limit.remainingPercent / 100);

  Widget meter(String text, double fraction) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: fraction.clamp(0, 1).toDouble()),
        const SizedBox(height: 12),
      ]);
}

class UsageCard extends StatelessWidget {
  final UsageReport usage;

  const UsageCard({super.key, required this.usage});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final totals = usage.totals;
    final textTheme = Theme.of(context).textTheme;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.cloudUsage, style: textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('${l10n.cloudRequests}: ${totals.requestCount}'),
              Text('${l10n.cloudSpend}: ${usd(totals.usageUsd, 4)}'),
              Text('${l10n.cloudTokens}: ${totals.inputTokens} in '
                  '(${totals.cachedInputTokens} cached) / '
                  '${totals.outputTokens} out'),
              const SizedBox(height: 12),
              SizedBox(height: 64, child: BucketBars(buckets: usage.buckets)),
              if (usage.byModel.isNotEmpty) ...[
                const Divider(height: 24),
                Text(l10n.cloudByModel, style: textTheme.titleSmall),
                for (final entry in usage.byModel)
                  ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry.model),
                      trailing: Text('${entry.metrics.requestCount} · '
                          '${usd(entry.metrics.usageUsd, 4)}')),
              ],
            ])));
  }
}

class BucketBars extends StatelessWidget {
  final List<UsageBucket> buckets;

  const BucketBars({super.key, required this.buckets});

  @override
  Widget build(BuildContext context) {
    var peak = 1;
    for (final bucket in buckets) {
      if (bucket.metrics.requestCount > peak) {
        peak = bucket.metrics.requestCount;
      }
    }
    final color = Theme.of(context).colorScheme.primary;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (final bucket in buckets)
        Expanded(
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: FractionallySizedBox(
                    heightFactor:
                        (bucket.metrics.requestCount / peak).clamp(0.03, 1),
                    // Partial = current hour/day still accumulating.
                    child: ColoredBox(
                        color: bucket.isPartial
                            ? color.withValues(alpha: 0.4)
                            : color)))),
    ]);
  }
}
