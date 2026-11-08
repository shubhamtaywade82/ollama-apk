import 'package:flutter/material.dart';

import '../main.dart';
import '../worker/clients.dart';
import '../worker/haptic.dart';
import '../worker/mcp.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

class ScreenSettingsMcp extends StatefulWidget {
  const ScreenSettingsMcp({super.key});

  @override
  State<ScreenSettingsMcp> createState() => _ScreenSettingsMcpState();
}

class _ScreenSettingsMcpState extends State<ScreenSettingsMcp> {
  Map<String, McpConnection> connections = {};
  bool connecting = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() => connecting = true);
    final connections = await connectMcpServers(httpClient);
    if (!mounted) return;
    setState(() {
      connecting = false;
      this.connections = {for (final c in connections) c.client.server.url: c};
    });
  }

  Future<void> add() async {
    final server = await showDialog<McpServer>(
        context: context, builder: (_) => const _AddMcpServerDialog());
    if (server == null) return;
    await saveMcpServers(secureStorage,
        [...mcpServers.where((s) => s.url != server.url), server]);
    refresh();
  }

  Future<void> remove(McpServer server) async {
    await saveMcpServers(
        secureStorage, mcpServers.where((s) => s.url != server.url).toList());
    refresh();
  }

  String status(McpServer server) {
    final l10n = AppLocalizations.of(context)!;
    final connection = connections[server.url];
    if (connection != null) {
      final enabled = connection.tools
          .where((t) => isMcpToolAllowed(prefs!, server, t.name))
          .length;
      return l10n.mcpToolsEnabled(enabled, connection.tools.length);
    }
    return mcpErrors[server.url] ?? (connecting ? '…' : '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitleMcp), actions: [
        IconButton(
            tooltip: l10n.hostsRefresh,
            onPressed: refresh,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: add,
          icon: const Icon(Icons.add_rounded),
          label: Text(l10n.mcpAdd)),
      body: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
        SwitchListTile(
            title: Text(l10n.mcpEnable),
            subtitle: Text(l10n.mcpEnableDescription),
            value: prefs!.getBool("mcpTools") ?? false,
            onChanged: (value) {
              selectionHaptic();
              prefs!.setBool("mcpTools", value);
              setState(() {});
            }),
        const Divider(),
        if (mcpServers.isEmpty)
          Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.mcpEmpty, textAlign: TextAlign.center)),
        for (final server in mcpServers)
          Dismissible(
            key: ValueKey(server.url),
            direction: DismissDirection.endToStart,
            background: Container(
                color: Theme.of(context).colorScheme.errorContainer,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.delete_rounded)),
            onDismissed: (_) => remove(server),
            child: ExpansionTile(
              leading: Icon(connections.containsKey(server.url)
                  ? Icons.extension_rounded
                  : Icons.extension_off_rounded),
              title: Text(server.name),
              subtitle: Text('${server.url}\n${status(server)}'),
              children: [
                for (final tool
                    in connections[server.url]?.tools ?? <McpTool>[])
                  SwitchListTile(
                      dense: true,
                      title: Text(tool.name),
                      subtitle: Text(tool.description,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      value: isMcpToolAllowed(prefs!, server, tool.name),
                      onChanged: (allowed) async {
                        selectionHaptic();
                        await setMcpToolAllowed(
                            prefs!, server, tool.name, allowed);
                        setState(() {});
                      }),
              ],
            ),
          ),
      ]),
    );
  }
}

class _AddMcpServerDialog extends StatefulWidget {
  const _AddMcpServerDialog();

  @override
  State<_AddMcpServerDialog> createState() => _AddMcpServerDialogState();
}

class _AddMcpServerDialogState extends State<_AddMcpServerDialog> {
  final name = TextEditingController();
  final url = TextEditingController(text: 'https://');
  final token = TextEditingController();
  String? urlError;
  String? testResult;
  bool testing = false;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    token.dispose();
    super.dispose();
  }

  /// The server described by the form, or null (with an error shown) when
  /// the URL is not usable.
  McpServer? readForm() {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.tryParse(url.text.trim());
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      setState(() => urlError = l10n.hostsInvalidUrl);
      return null;
    }
    // A bearer token over plain HTTP would be readable on the network.
    if (token.text.trim().isNotEmpty && uri.scheme != 'https') {
      setState(() => urlError = l10n.mcpTokenNeedsHttps);
      return null;
    }
    setState(() => urlError = null);
    final label = name.text.trim();
    return McpServer(
        name: label.isEmpty ? uri.host : label,
        url: uri.toString(),
        token: token.text.trim());
  }

  Future<void> test() async {
    final l10n = AppLocalizations.of(context)!;
    final server = readForm();
    if (server == null) return;
    setState(() {
      testing = true;
      testResult = null;
    });
    String result;
    try {
      final client = McpClient(httpClient, server);
      await client.initialize();
      result = l10n.mcpToolCount((await client.listTools()).length);
    } catch (e) {
      result = l10n.hostsTestFailed('$e');
    }
    if (!mounted) return;
    setState(() {
      testing = false;
      testResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.mcpAdd),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: InputDecoration(labelText: l10n.hostsName)),
          TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                  labelText: l10n.hostsUrl, errorText: urlError)),
          TextField(
              controller: token,
              obscureText: true,
              decoration: InputDecoration(labelText: l10n.mcpToken)),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(
                onPressed: testing ? null : test, child: Text(l10n.hostsTest)),
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
        FilledButton(
            onPressed: () {
              final server = readForm();
              if (server != null) Navigator.pop(context, server);
            },
            child: Text(l10n.mcpAdd)),
      ],
    );
  }
}
