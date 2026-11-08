import 'package:flutter/material.dart';

import '../worker/clients.dart';
import '../worker/haptic.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// Installed models plus, for each loaded one, its VRAM footprint.
typedef ModelInventory = (List<llama.Model>, Map<String, int>);

Future<ModelInventory> loadInventory() async {
  final (installed, running) =
      await (ollamaClient.listModels(), ollamaClient.listRunningModels()).wait;
  final loaded = {
    for (final m in running.models ?? <llama.ProcessModel>[])
      if (m.model != null) m.model!: m.sizeVram ?? 0
  };
  return (installed.models ?? <llama.Model>[], loaded);
}

class ScreenSettingsModels extends StatefulWidget {
  const ScreenSettingsModels({super.key});

  @override
  State<ScreenSettingsModels> createState() => _ScreenSettingsModelsState();
}

class _ScreenSettingsModelsState extends State<ScreenSettingsModels> {
  late Future<ModelInventory> inventory = loadInventory();

  void refresh() => setState(() => inventory = loadInventory());

  Future<void> unload(String name) async {
    await ollamaClient.generateCompletion(
        request: llama.GenerateCompletionRequest(
            model: name, prompt: '', keepAlive: 0));
    refresh();
  }

  Future<void> delete(String name) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(l10n.modelsDeleteTitle(name)),
                content: Text(l10n.modelsDeleteBody),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(
                          MaterialLocalizations.of(context).cancelButtonLabel)),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(l10n.modelsDelete)),
                ]));
    if (confirmed != true) return;
    await ollamaClient.deleteModel(
        request: llama.DeleteModelRequest(model: name));
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitleModels), actions: [
        IconButton(
            tooltip: l10n.hostsRefresh,
            onPressed: refresh,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      body: FutureBuilder(
          future: inventory,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('${snap.error}'));
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final (installed, loaded) = snap.data!;
            if (installed.isEmpty) {
              return Center(child: Text(l10n.modelsEmpty));
            }
            return ListView(children: [
              for (final m in installed) tile(m, loaded[m.model]),
            ]);
          }),
    );
  }

  Widget tile(llama.Model entry, int? vramBytes) {
    final l10n = AppLocalizations.of(context)!;
    final name = entry.model ?? '';
    final details = entry.details;
    final facts = [
      formatBytes(entry.size ?? 0),
      if (details?.parameterSize != null) details!.parameterSize!,
      if (details?.quantizationLevel != null) details!.quantizationLevel!,
      if (vramBytes != null) '${l10n.modelsLoaded} ${formatBytes(vramBytes)}',
    ];
    return ListTile(
      leading: Icon(vramBytes != null
          ? Icons.memory_rounded
          : Icons.inventory_2_outlined),
      title: Text(name),
      subtitle: Text(facts.join('  ·  ')),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (vramBytes != null)
          IconButton(
              tooltip: l10n.modelsUnload,
              onPressed: () {
                selectionHaptic();
                unload(name);
              },
              icon: const Icon(Icons.eject_rounded)),
        IconButton(
            tooltip: l10n.modelsDelete,
            onPressed: () => delete(name),
            icon: const Icon(Icons.delete_outline_rounded)),
      ]),
    );
  }
}
