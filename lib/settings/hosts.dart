import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../main.dart';
import '../worker/clients.dart';
import '../worker/haptic.dart';
import '../worker/hosts.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

class ScreenSettingsHosts extends StatefulWidget {
  const ScreenSettingsHosts({super.key});

  @override
  State<ScreenSettingsHosts> createState() => _ScreenSettingsHostsState();
}

class _ScreenSettingsHostsState extends State<ScreenSettingsHosts> {
  List<OllamaHost> hosts = loadHosts(prefs!);
  final Map<String, HostHealth> health = {};

  @override
  void initState() {
    super.initState();
    refreshHealth();
  }

  void refreshHealth() {
    health.clear();
    for (final h in hosts) {
      pingHost(h, httpClient).then((result) {
        if (mounted) setState(() => health[h.url] = result);
      });
    }
    setState(() {});
  }

  Future<void> add() async {
    final host = await showDialog<OllamaHost>(
        context: context, builder: (_) => const _AddHostDialog());
    if (host == null) return;
    hosts = await upsertHost(prefs!, host);
    if (hosts.length == 1) await makeActive(host);
    refreshHealth();
  }

  Future<void> makeActive(OllamaHost target) async {
    await activateHost(prefs!, target);
    setState(() => host = target.url);
  }

  Future<void> remove(OllamaHost target) async {
    hosts = await removeHost(prefs!, target.url);
    refreshHealth();
  }

  Future<void> reorder(int from, int to) async {
    hosts.insert(to, hosts.removeAt(from));
    await saveHosts(prefs!, hosts);
    setState(() {});
  }

  Widget statusDot(OllamaHost h) {
    final result = health[h.url];
    final color = result == null
        ? Colors.grey
        : result.isUp
            ? Colors.green
            : Theme.of(context).colorScheme.error;
    return Icon(Icons.circle, size: 12, color: color);
  }

  String subtitle(OllamaHost h) {
    final result = health[h.url];
    final latency = result?.latency;
    final status = result == null
        ? '…'
        : result.isUp
            ? '${latency!.inMilliseconds} ms'
            : result.error!;
    return '${h.url}  ·  $status';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitleHosts), actions: [
        IconButton(
            tooltip: l10n.hostsRefresh,
            onPressed: refreshHealth,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: add,
          icon: const Icon(Icons.add_rounded),
          label: Text(l10n.hostsAdd)),
      body: hosts.isEmpty
          ? Center(child: Text(l10n.hostsEmpty))
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: hosts.length,
              onReorderItem: reorder,
              itemBuilder: (context, i) => tile(hosts[i], i),
            ),
    );
  }

  Widget tile(OllamaHost h, int index) {
    final isActive = h.url == host;
    return Dismissible(
      key: ValueKey(h.url),
      direction: DismissDirection.endToStart,
      background: Container(
          color: Theme.of(context).colorScheme.errorContainer,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: const Icon(Icons.delete_rounded)),
      onDismissed: (_) => remove(h),
      child: ListTile(
        leading: statusDot(h),
        title: Text(h.name),
        subtitle: Text(subtitle(h)),
        trailing: isActive
            ? const Icon(Icons.check_circle_rounded)
            : ReorderableDragStartListener(
                index: index, child: const Icon(Icons.drag_handle_rounded)),
        selected: isActive,
        onTap: () {
          selectionHaptic();
          makeActive(h);
        },
      ),
    );
  }
}

class _AddHostDialog extends StatefulWidget {
  const _AddHostDialog();

  @override
  State<_AddHostDialog> createState() => _AddHostDialogState();
}

class _AddHostDialogState extends State<_AddHostDialog> {
  final name = TextEditingController();
  final url = TextEditingController(text: 'http://');
  final apiKey = TextEditingController();
  String? urlError;
  String? testResult;
  bool testing = false;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    apiKey.dispose();
    super.dispose();
  }

  void submit() {
    final normalized = normalizeHostUrl(url.text);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      setState(() => urlError = AppLocalizations.of(context)!.hostsInvalidUrl);
      return;
    }
    final label = name.text.trim();
    if (isCloudHost(normalized)) saveCloudApiKey(apiKey.text.trim());
    Navigator.pop(context,
        OllamaHost(name: label.isEmpty ? uri.host : label, url: normalized));
  }

  Future<void> testConnection() async {
    final l10n = AppLocalizations.of(context)!;
    final normalized = normalizeHostUrl(url.text);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      setState(() => urlError = l10n.hostsInvalidUrl);
      return;
    }
    setState(() {
      urlError = null;
      testing = true;
      testResult = null;
    });
    final key = apiKey.text.trim();
    final health = await pingHost(
        OllamaHost(name: uri.host, url: normalized), httpClient,
        headers: isCloudHost(normalized) && key.isNotEmpty
            ? {'Authorization': 'Bearer $key'}
            : null);
    if (!mounted) return;
    setState(() {
      testing = false;
      testResult = health.isUp
          ? l10n.hostsTestOk(health.latency!.inMilliseconds)
          : l10n.hostsTestFailed(health.error!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showLoopbackWarning =
        isLoopbackOnPhone(url.text, defaultTargetPlatform);
    return AlertDialog(
      title: Text(l10n.hostsAdd),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: InputDecoration(labelText: l10n.hostsName)),
          TextField(
              controller: url,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() => testResult = null),
              decoration: InputDecoration(
                  labelText: l10n.hostsUrl, errorText: urlError)),
          if (isPublicHttp(url.text))
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.hostsPublicHttpWarning,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (showLoopbackWarning)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.hostsLoopbackWarning,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          TextField(
              controller: apiKey,
              obscureText: true,
              decoration: InputDecoration(labelText: l10n.settingsApiKey)),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(
                onPressed: testing ? null : testConnection,
                child: Text(l10n.hostsTest)),
            const SizedBox(width: 12),
            if (testing)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            if (testResult != null) Expanded(child: Text(testResult!)),
          ]),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
        FilledButton(onPressed: submit, child: Text(l10n.hostsAdd)),
      ],
    );
  }
}
