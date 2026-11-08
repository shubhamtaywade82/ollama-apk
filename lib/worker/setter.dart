import 'chat_store.dart';
import '../settings/models.dart' show formatBytes;
import '../thinking_block.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'desktop.dart';
import 'haptic.dart';
import '../main.dart';
import 'sender.dart';
import 'clients.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:dartx/dartx.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

const _modelInfoTimeout = Duration(seconds: 10);

// Capability names as Ollama reports them in /api/show and /api/tags.
const capabilityTools = "tools";
const capabilityThinking = "thinking";
const capabilityVision = "vision";

final _capabilityCache = <String, Set<String>>{};

/// Capabilities the server reports for [name]. Empty when the lookup fails,
/// so a feature that needs one stays off instead of failing the request.
Future<Set<String>> modelCapabilities(String name) async {
  final key = "$host|$name";
  final cached = _capabilityCache[key];
  if (cached != null) return cached;
  try {
    final details = await ollamaClient.models
        .show(request: llama.ShowRequest(model: name))
        .timeout(_modelInfoTimeout);
    return _capabilityCache[key] = (details.capabilities ?? []).toSet();
  } catch (_) {
    return {};
  }
}

/// Whether [entry] accepts images. A slow or failing metadata call only
/// hides the image button for that model; it never blocks the model list.
Future<bool> supportsVisionInput(llama.ModelSummary entry) async {
  if ((entry.details?.families ?? []).contains("clip")) return true;
  // Newer servers list capabilities with the model; older ones need /show.
  final listed = entry.capabilities;
  if (listed != null) return listed.contains(capabilityVision);
  try {
    final details = await ollamaClient.models
        .show(request: llama.ShowRequest(model: entry.model!))
        .timeout(_modelInfoTimeout);
    return (details.capabilities ?? []).contains(capabilityVision);
  } catch (_) {
    return false;
  }
}

void setModel(BuildContext context, Function setState) {
  List<String> models = [];
  List<String> modelsReal = [];
  List<bool> modal = [];
  List<String> facts = [];
  String query = "";
  int usedIndex = -1;
  int oldIndex = -1;
  int addIndex = -1;
  bool loaded = false;
  Function? setModalState;
  desktopTitleVisible = false;
  setState(() {});
  void load() async {
    try {
      var list = await ollamaClient.models.list().timeout(Duration(
          seconds:
              (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0)).round()));
      final visionFlags = <bool>[];
      // Batches of 4 so a host with many models is not hit by one burst.
      for (final batch in list.models!.chunked(4)) {
        visionFlags.addAll(await Future.wait(batch.map(supportsVisionInput)));
      }
      for (var i = 0; i < list.models!.length; i++) {
        final entry = list.models![i];
        models.add(entry.model!.split(":")[0]);
        modelsReal.add(entry.model!);
        modal.add(visionFlags[i]);
        facts.add([
          if (entry.details?.parameterSize != null)
            entry.details!.parameterSize!,
          if (entry.details?.quantizationLevel != null)
            entry.details!.quantizationLevel!,
          if ((entry.size ?? 0) > 0) formatBytes(entry.size!),
        ].join("  ·  "));
      }

      addIndex = models.length;
      // ignore: use_build_context_synchronously
      models.add(AppLocalizations.of(context)!.modelDialogAddModel);
      // ignore: use_build_context_synchronously
      modelsReal.add(AppLocalizations.of(context)!.modelDialogAddModel);
      modal.add(false);
      facts.add("");

      for (var i = 0; i < modelsReal.length; i++) {
        if (modelsReal[i] == model) {
          usedIndex = i;
          oldIndex = usedIndex;
        }
      }
      if (prefs!.getBool("modelTags") == null) {
        List duplicateFinder = [];
        for (var model in models) {
          if (duplicateFinder.contains(model)) {
            prefs!.setBool("modelTags", true);
            break;
          } else {
            duplicateFinder.add(model);
          }
        }
      }
      loaded = true;
      setModalState!(() {});
    } catch (_) {
      setState(() {
        desktopTitleVisible = true;
      });
      // ignore: use_build_context_synchronously
      Navigator.of(context).pop();
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              // ignore: use_build_context_synchronously
              AppLocalizations.of(context)!.settingsHostInvalid("timeout")),
          showCloseIcon: true));
    }
  }

  if (useModel) return;
  selectionHaptic();

  load();

  /// One picker row: name (tag greyed), size facts, capability icons and a
  /// check on the current model. Tapping selects and closes the sheet.
  Widget modelRow(BuildContext context, int index, StateSetter setLocalState) {
    final isAdd = index == addIndex;
    final isSelected = usedIndex == index;
    final parts = modelsReal[index].split(":");
    final showTag = (prefs!.getBool("modelTags") ?? true) && parts.length > 1;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      selected: isSelected,
      leading: isAdd ? const Icon(Icons.add_rounded) : null,
      title: Text.rich(TextSpan(children: [
        TextSpan(
            text: models[index],
            style: const TextStyle(fontWeight: FontWeight.w600)),
        if (showTag && !isAdd)
          TextSpan(text: ":${parts[1]}", style: TextStyle(color: muted)),
      ])),
      subtitle: facts[index].isEmpty ? null : Text(facts[index]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (recommendedModels.contains(models[index]))
          Icon(Icons.star_rounded, size: 18, color: muted),
        if (modal[index])
          Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.image_outlined, size: 18, color: muted)),
        if (isSelected)
          const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Icon(Icons.check_rounded)),
      ]),
      onTap: () {
        selectionHaptic();
        if (isAdd) {
          usedIndex = oldIndex;
          Navigator.of(context).pop();
          addModel(context, setState);
          return;
        }
        if (!chatAllowed && model != null) return;
        setLocalState(() => usedIndex = index);
        // maybePop goes through PopScope, which applies the selection.
        Navigator.of(context).maybePop();
      },
    );
  }

  var content = StatefulBuilder(builder: (context, setLocalState) {
    setModalState = setLocalState;
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (!loaded) return;
          loaded = false;
          bool preload = false;
          if (usedIndex >= 0 && modelsReal[usedIndex] != model) {
            preload = true;
            if (prefs!.getBool("resetOnModelSelect") ??
                true && allowMultipleChats) {
              messages = [];
              chatUuid = null;
            }
          }
          model = (usedIndex >= 0) ? modelsReal[usedIndex] : null;
          chatAllowed = !(model == null);
          multimodal = (usedIndex >= 0) ? modal[usedIndex] : false;
          if (model != null) {
            prefs?.setString("model", model!);
          } else {
            prefs?.remove("model");
          }
          prefs?.setBool("multimodal", multimodal);

          if (model != null &&
              preload &&
              int.parse(prefs!.getString("keepAlive") ?? "300") != 0 &&
              (prefs!.getBool("preloadModel") ?? true)) {
            setLocalState(() {});
            try {
              // don't use llama client, package doesn't support just loading without content
              final preloadUri = isCloudHost(host)
                  ? Uri.parse("https://ollama.com/api/generate")
                  : Uri.parse("$host/api/generate");
              final preloadHeaders = <String, String>{
                "Content-Type": "application/json",
                ...customHostHeaders(host)
              };
              if (isCloudHost(host)) {
                preloadHeaders["Authorization"] = "Bearer $cloudApiKey";
              }
              await httpClient
                  .post(preloadUri,
                      headers: preloadHeaders,
                      body: jsonEncode({
                        "model": model!,
                        "keep_alive":
                            int.parse(prefs!.getString("keepAlive") ?? "300")
                      }))
                  .timeout(Duration(
                      seconds: (10.0 *
                              (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                          .round()));
            } catch (_) {
              // ignore: use_build_context_synchronously
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  // ignore: use_build_context_synchronously
                  content: Text(AppLocalizations.of(context)!
                      .settingsHostInvalid("timeout")),
                  showCloseIcon: true));
              setState(() {
                model = null;
                chatAllowed = false;
              });
            }
            setState(() {
              desktopTitleVisible = true;
            });
            // ignore: use_build_context_synchronously
            Navigator.of(context).pop();
          } else {
            setState(() {
              desktopTitleVisible = true;
            });
            try {
              Navigator.of(context).pop();
            } catch (_) {}
          }
        },
        child: Container(
            width: desktopLayout(context) ? null : double.infinity,
            padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: desktopLayout(context) ? 16 : 0),
            child: (!loaded)
                ? SizedBox(
                    width: desktopLayout(context) ? 300 : double.infinity,
                    child: const LinearProgressIndicator())
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    if (models.length > 9)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                              autofocus: false,
                              decoration: InputDecoration(
                                  prefixIcon: const Icon(Icons.search_rounded),
                                  hintText: AppLocalizations.of(context)!
                                      .modelSearchHint,
                                  border: const OutlineInputBorder(),
                                  isDense: true),
                              onChanged: (value) => setLocalState(
                                  () => query = value.trim().toLowerCase()))),
                    Container(
                        width: desktopLayout(context) ? 360 : double.infinity,
                        constraints: BoxConstraints(
                            maxHeight:
                                MediaQuery.of(context).size.height * 0.7),
                        child: ListView(shrinkWrap: true, children: [
                          for (var index = 0; index < models.length; index++)
                            if (index == addIndex ||
                                query.isEmpty ||
                                modelsReal[index].toLowerCase().contains(query))
                              modelRow(context, index, setLocalState),
                        ])),
                    const SizedBox(height: 8),
                  ])));
  });

  if (desktopLayoutNotRequired(context)) {
    showDialog(
        context: context,
        builder: (context) {
          return Transform.translate(
            offset: desktopLayoutRequired(context)
                ? const Offset(289, 0)
                : const Offset(0, 0),
            child: Dialog(
                surfaceTintColor:
                    (Theme.of(context).brightness == Brightness.dark)
                        ? Colors.grey[800]
                        : null,
                alignment: desktopLayoutRequired(context)
                    ? Alignment.topLeft
                    : Alignment.topCenter,
                child: content),
          );
        });
  } else {
    // Scroll-controlled so the sheet can grow to the list's 70% cap instead
    // of the default 9/16, which clipped the bottom rows of long lists.
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => content);
  }
}

void addModel(BuildContext context, Function setState) async {
  bool canceled = false;
  bool networkError = false;
  bool ratelimitError = false;
  bool alreadyExists = false;
  final String invalidText =
      AppLocalizations.of(context)!.modelDialogAddPromptInvalid;
  final networkErrorText =
      AppLocalizations.of(context)!.settingsHostInvalid("other");
  final timeoutErrorText =
      AppLocalizations.of(context)!.settingsHostInvalid("timeout");
  final ratelimitErrorText =
      AppLocalizations.of(context)!.settingsHostInvalid("ratelimit");
  final alreadyExistsText =
      AppLocalizations.of(context)!.modelDialogAddPromptAlreadyExists;
  final downloadSuccessText =
      AppLocalizations.of(context)!.modelDialogAddDownloadSuccess;
  final downloadFailedText =
      AppLocalizations.of(context)!.modelDialogAddDownloadFailed;
  var requestedModel = await prompt(
    context,
    title: AppLocalizations.of(context)!.modelDialogAddPromptTitle,
    description: AppLocalizations.of(context)!.modelDialogAddPromptDescription,
    placeholder: "llama3:latest",
    enableSuggestions: false,
    validator: (content) async {
      var model = content.trim();
      model = model.removeSuffix(":latest");
      if (model == "") return false;
      canceled = false;
      networkError = false;
      ratelimitError = false;
      alreadyExists = false;
      try {
        var request = await ollamaClient.models.list().timeout(Duration(
            seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                .round()));
        for (var element in request.models!) {
          var localModel = element.model!.removeSuffix(":latest");
          if (localModel == model) {
            alreadyExists = true;
          }
        }
        if (alreadyExists) return false;
      } catch (_) {
        networkError = true;
        return false;
      }
      var endpoint = "https://ollama.com/library/";
      if (kIsWeb) {
        if (!(prefs!.getBool("allowWebProxy") ?? false)) {
          bool returnValue = false;
          await showDialog(
              context: mainContext!,
              barrierDismissible: false,
              builder: (context) {
                return AlertDialog(
                    title: Text(AppLocalizations.of(context)!
                        .modelDialogAddAllowanceTitle),
                    content: SizedBox(
                      width: 640,
                      child: Text(AppLocalizations.of(context)!
                          .modelDialogAddAllowanceDescription),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () {
                            canceled = true;
                            Navigator.of(context).pop();
                          },
                          child: Text(AppLocalizations.of(context)!
                              .modelDialogAddAllowanceDeny)),
                      TextButton(
                          onPressed: () {
                            returnValue = true;
                            Navigator.of(context).pop();
                          },
                          child: Text(AppLocalizations.of(context)!
                              .modelDialogAddAllowanceAllow))
                    ]);
              });
          if (!returnValue) return false;
          prefs!.setBool("allowWebProxy", true);
        }
        endpoint = "https://end.jhubi1.com/ollama-proxy/";
      }
      http.Response response;
      try {
        response = await httpClient
            .get(Uri.parse("$endpoint${Uri.encodeComponent(model)}"))
            .timeout(Duration(
                seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                    .round()));
      } catch (_) {
        networkError = true;
        return false;
      }
      if (response.statusCode == 200) {
        bool returnValue = false;
        await showDialog(
            context: mainContext!,
            barrierDismissible: false,
            builder: (context) {
              return AlertDialog(
                  title: Text(AppLocalizations.of(context)!
                      .modelDialogAddAssuranceTitle(model)),
                  content: SizedBox(
                    width: 640,
                    child: Text(AppLocalizations.of(context)!
                        .modelDialogAddAssuranceDescription(model)),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () {
                          canceled = true;
                          Navigator.of(context).pop();
                        },
                        child: Text(AppLocalizations.of(context)!
                            .modelDialogAddAssuranceCancel)),
                    TextButton(
                        onPressed: () {
                          returnValue = true;
                          Navigator.of(context).pop();
                        },
                        child: Text(AppLocalizations.of(context)!
                            .modelDialogAddAssuranceAdd))
                  ]);
            });
        return returnValue;
      }
      if (response.statusCode == 429) {
        ratelimitError = true;
      }
      return false;
    },
    validatorErrorCallback: (content) {
      if (networkError) return networkErrorText;
      if (ratelimitError) return ratelimitErrorText;
      if (alreadyExists) return alreadyExistsText;
      if (canceled) return null;
      return invalidText;
    },
  );
  if (requestedModel == "") return;
  requestedModel = requestedModel.removeSuffix(":latest");
  double? percent;
  Function? setDialogState;
  showModalBottomSheet(
      context: mainContext!,
      builder: (context) {
        return StatefulBuilder(builder: (context, setLocalState) {
          setDialogState = setLocalState;
          return PopScope(
              canPop: false,
              child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                      bottom: desktopLayout(context) ? 16 : 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        percent == null
                            ? AppLocalizations.of(context)!
                                .modelDialogAddDownloadPercentLoading
                            : AppLocalizations.of(context)!
                                .modelDialogAddDownloadPercent(
                                    (percent * 100).round().toString()),
                      ),
                      const Padding(padding: EdgeInsets.only(top: 8)),
                      LinearProgressIndicator(value: percent),
                    ],
                  )));
        });
      });
  try {
    final stream = ollamaClient.models
        .pullStream(request: llama.PullRequest(model: requestedModel))
        .timeout(Duration(
            seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                .round()));
    bool alreadyProgressed = false;
    await for (final res in stream) {
      double tmpPercent =
          ((res.completed ?? 0).toInt() / (res.total ?? 100).toInt());
      if ((tmpPercent * 100).round() == 0) {
        if (!alreadyProgressed) {
          percent = null;
        }
      } else {
        percent = tmpPercent;
        alreadyProgressed = true;
      }
      setDialogState!(() {});
    }
    // done downloading
    if (prefs!.getBool("resetOnModelSelect") ?? true && allowMultipleChats) {
      messages = [];
      chatUuid = null;
    }
    model = requestedModel;
    if (model!.split(":").length == 1) {
      model = "$model:latest";
    }
    bool exists = false;
    try {
      var request = await ollamaClient.models.list().timeout(Duration(
          seconds:
              (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0)).round()));
      for (var element in request.models!) {
        if (element.model == model) {
          exists = true;
          multimodal = (element.details!.families ?? []).contains("clip");
        }
      }
      if (!exists) {
        throw Exception();
      }
    } catch (_) {
      setState(() {
        model = null;
        multimodal = false;
        chatAllowed = false;
      });
      prefs?.remove("model");
      prefs?.setBool("multimodal", multimodal);
      Navigator.of(mainContext!).pop();
      if (!exists) {
        ScaffoldMessenger.of(mainContext!).showSnackBar(
            SnackBar(content: Text(downloadFailedText), showCloseIcon: true));
      } else {
        ScaffoldMessenger.of(mainContext!).showSnackBar(
            SnackBar(content: Text(timeoutErrorText), showCloseIcon: true));
      }
      return;
    }
    prefs?.setString("model", model!);
    prefs?.setBool("multimodal", multimodal);
    setState(() {
      chatAllowed = true;
    });
    Navigator.of(mainContext!).pop();
    ScaffoldMessenger.of(mainContext!).showSnackBar(
        SnackBar(content: Text(downloadSuccessText), showCloseIcon: true));
  } catch (_) {
    Navigator.of(mainContext!).pop();
    ScaffoldMessenger.of(mainContext!).showSnackBar(
        SnackBar(content: Text(downloadFailedText), showCloseIcon: true));
  }
}

void saveChat(String uuid, Function setState) async {
  int index = -1;
  for (var i = 0; i < chats.length; i++) {
    if (jsonDecode(chats[i])["uuid"] == uuid) {
      index = i;
    }
  }
  if (index == -1) return;
  List<Map<String, String>> history = [];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message is types.FileMessage) {
      history.add({
        "role": "user",
        "type": "file",
        "name": message.name,
        "size": message.size.toString(),
        "content": '${message.metadata?['text'] ?? ''}',
      });
      continue;
    }
    if ((jsonDecode(jsonEncode(messages[i])) as Map).containsKey("text")) {
      final thinking = thinkingOf(messages[i].metadata);
      history.add({
        "role": (messages[i].author == user) ? "user" : "assistant",
        "content": jsonDecode(jsonEncode(messages[i]))["text"],
        "thinking": ?thinking,
      });
    } else {
      var uri = jsonDecode(jsonEncode(messages[i]))["uri"] as String;
      String content = (uri.startsWith("data:image/png;base64,"))
          ? uri.removePrefix("data:image/png;base64,")
          : base64.encode(await File(uri).readAsBytes());
      history.add({
        "role": (messages[i].author == user) ? "user" : "assistant",
        "type": "image",
        "name": (messages[i] as types.ImageMessage).name,
        "size": (messages[i] as types.ImageMessage).size.toString(),
        "content": content
      });
    }
  }
  if (messages.isEmpty && uuid == chatUuid) {
    for (var i = 0; i < chats.length; i++) {
      if (jsonDecode(chats[i])["uuid"] == chatUuid) {
        List<String> tmp = List.of(chats);
        tmp.removeAt(i);
        saveChats(tmp);
        chatUuid = null;
        return;
      }
    }
  }
  if (jsonDecode(chats[index])["messages"].length >= 1) {
    if (jsonDecode(jsonDecode(chats[index])["messages"])[0]["role"] ==
        "system") {
      history.add({
        "role": "system",
        "content": jsonDecode(jsonDecode(chats[index])["messages"])[0]
            ["content"]
      });
    }
  } else {
    var system = prefs?.getString("system") ?? "You are a helpful assistant";
    if (prefs!.getBool("noMarkdown") ?? false) {
      system +=
          " You must not use markdown or any other formatting language in any way!";
    }
    history.add({"role": "system", "content": system});
  }
  history = history.reversed.toList();
  List<String> tmp = List.of(chats);
  tmp.removeAt(index);
  tmp.insert(
      0,
      jsonEncode({
        "title": jsonDecode(chats[index])["title"],
        "uuid": uuid,
        "model": model,
        "messages": jsonEncode(history)
      }));
  saveChats(tmp);
  setState(() {});
}

void loadChat(String uuid, Function setState) {
  int index = -1;
  for (var i = 0; i < chats.length; i++) {
    if (jsonDecode(chats[i])["uuid"] == uuid) {
      index = i;
    }
  }
  if (index == -1) return;
  messages = [];
  model = null;
  setState(() {});
  var history = jsonDecode(jsonDecode(chats[index])["messages"]);
  for (var i = 0; i < history.length; i++) {
    if (history[i]["role"] != "system") {
      if (history[i]["type"] == "file") {
        messages.insert(
            0,
            types.FileMessage(
                author: user,
                id: const Uuid().v4(),
                name: history[i]["name"],
                size: int.tryParse("${history[i]["size"]}") ?? 0,
                uri: history[i]["name"],
                metadata: {"text": history[i]["content"]}));
      } else if ((history[i] as Map).containsKey("type") &&
          history[i]["type"] == "image") {
        messages.insert(
            0,
            types.ImageMessage(
                author: (history[i]["role"] == "user") ? user : assistant,
                id: const Uuid().v4(),
                name: history[i]["name"],
                size: int.parse(history[i]["size"]),
                uri: "data:image/png;base64,${history[i]["content"]}"));
      } else {
        messages.insert(
            0,
            types.TextMessage(
                author: (history[i]["role"] == "user") ? user : assistant,
                id: const Uuid().v4(),
                text: history[i]["content"],
                metadata: history[i]["thinking"] is String
                    ? {"thinking": history[i]["thinking"]}
                    : null));
      }
    }
  }
  model = jsonDecode(chats[index])["model"];
  setState(() {});
}

Future<bool> deleteChatDialog(BuildContext context, Function setState,
    {bool takeAction = true,
    bool? additionalCondition,
    String? uuid,
    bool popSidebar = false}) async {
  additionalCondition ??= true;
  uuid ??= chatUuid;

  bool returnValue = false;
  void delete(BuildContext context) {
    returnValue = true;
    if (takeAction) {
      for (var i = 0; i < chats.length; i++) {
        if (jsonDecode(chats[i])["uuid"] == uuid) {
          List<String> tmp = List.of(chats);
          tmp.removeAt(i);
          saveChats(tmp);
          break;
        }
      }
      if (chatUuid == uuid) {
        messages = [];
        chatUuid = null;
        if (!desktopLayoutRequired(context) &&
            Navigator.of(context).canPop() &&
            popSidebar) {
          Navigator.of(context).pop();
        }
      }
    }
  }

  if ((prefs!.getBool("askBeforeDeletion") ?? false) && additionalCondition) {
    await showDialog(
        context: context,
        builder: (context) {
          return StatefulBuilder(builder: (context, setLocalState) {
            return AlertDialog(
                title: Text(AppLocalizations.of(context)!.deleteDialogTitle),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(AppLocalizations.of(context)!.deleteDialogDescription),
                ]),
                actions: [
                  TextButton(
                      onPressed: () {
                        selectionHaptic();
                        Navigator.of(context).pop();
                      },
                      child: Text(
                          AppLocalizations.of(context)!.deleteDialogCancel)),
                  TextButton(
                      onPressed: () {
                        selectionHaptic();
                        Navigator.of(context).pop();
                        delete(context);
                      },
                      child: Text(
                          AppLocalizations.of(context)!.deleteDialogDelete))
                ]);
          });
        });
  } else {
    delete(context);
  }
  setState(() {});
  return returnValue;
}

Future<String> prompt(BuildContext context,
    {String description = "",
    String value = "",
    String title = "",
    String? valueIfCanceled,
    TextInputType keyboard = TextInputType.text,
    bool autocorrect = true,
    Iterable<String> autofillHints = const [],
    bool enableSuggestions = true,
    Icon? prefixIcon,
    int maxLines = 1,
    String? uuid,
    Future<bool> Function(String content)? validator,
    String? validatorError,
    String? Function(String content)? validatorErrorCallback,
    String? placeholder,
    bool prefill = true}) async {
  var returnText = (valueIfCanceled != null) ? valueIfCanceled : value;
  final TextEditingController controller =
      TextEditingController(text: prefill ? value : "");
  bool loading = false;
  String? error;
  await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, setLocalState) {
          void submit() async {
            selectionHaptic();
            if (validator != null) {
              setLocalState(() {
                error = null;
                loading = true;
              });
              bool valid = await validator(controller.text);
              setLocalState(() {
                loading = false;
              });
              if (!valid) {
                setLocalState(() {
                  if (validatorError != null) {
                    error = validatorError;
                  } else if (validatorErrorCallback != null) {
                    error = validatorErrorCallback(controller.text);
                  } else {
                    error = null;
                  }
                });
                return;
              }
            }
            returnText = controller.text;
            // ignore: use_build_context_synchronously
            Navigator.of(context).pop();
          }

          return PopScope(
              child: Container(
                  padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                      bottom: desktopFeature(web: true)
                          ? 12
                          : MediaQuery.of(context).viewInsets.bottom),
                  width: double.infinity,
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        (title != "")
                            ? Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))
                            : const SizedBox.shrink(),
                        (title != "")
                            ? const Divider()
                            : const SizedBox.shrink(),
                        (description != "")
                            ? Text(description)
                            : const SizedBox.shrink(),
                        const SizedBox(height: 8),
                        TextField(
                            controller: controller,
                            autofocus: true,
                            keyboardType: keyboard,
                            autocorrect: autocorrect,
                            autofillHints: autofillHints,
                            enableSuggestions: enableSuggestions,
                            maxLines: maxLines,
                            onSubmitted: (_) => submit(),
                            decoration: InputDecoration(
                                border: const OutlineInputBorder(),
                                hintText: placeholder,
                                errorText: error,
                                suffixIcon: IconButton(
                                    enableFeedback: false,
                                    tooltip: AppLocalizations.of(context)!
                                        .tooltipSave,
                                    onPressed: submit,
                                    icon: const Icon(Icons.save_rounded)),
                                prefixIcon: (title ==
                                            AppLocalizations.of(context)!
                                                .dialogEnterNewTitle &&
                                        uuid != null)
                                    ? IconButton(
                                        enableFeedback: false,
                                        tooltip: AppLocalizations.of(context)!
                                            .tooltipLetAIThink,
                                        onPressed: () async {
                                          selectionHaptic();
                                          setLocalState(() {
                                            loading = true;
                                          });

                                          try {
                                            var title = await getTitleAi(
                                                getHistoryString(uuid));
                                            controller.text = title;
                                            setLocalState(() {
                                              loading = false;
                                            });
                                          } catch (_) {
                                            try {
                                              setLocalState(() {
                                                loading = false;
                                              });
                                              // ignore: use_build_context_synchronously
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(SnackBar(
                                                      content: Text(
                                                          AppLocalizations.of(
                                                                  // ignore: use_build_context_synchronously
                                                                  context)!
                                                              .settingsHostInvalid(
                                                                  "timeout")),
                                                      showCloseIcon: true));
                                            } catch (_) {}
                                          }
                                        },
                                        icon: const Icon(
                                            Icons.auto_awesome_rounded))
                                    : prefixIcon)),
                        SizedBox(
                            height: 3,
                            child: (loading)
                                ? const LinearProgressIndicator()
                                : const SizedBox.shrink()),
                        (MediaQuery.of(context).viewInsets.bottom != 0)
                            ? const SizedBox(height: 16)
                            : const SizedBox.shrink()
                      ])));
        });
      });
  return returnText;
}
