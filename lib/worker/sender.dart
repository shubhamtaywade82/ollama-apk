// ignore_for_file: use_build_context_synchronously
import 'chat_store.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ollama_app/worker/clients.dart';

import 'agent.dart';
import 'attachments.dart';
import 'mcp.dart';
import 'hosts.dart';
import 'haptic.dart';
import 'setter.dart';
import '../main.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:ollama_dart/ollama_dart.dart' as llama;
import 'package:dartx/dartx.dart';
import 'package:uuid/uuid.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
// import 'package:scroll_to_index/scroll_to_index.dart';

List<String> images = [];

/// Files attached since the last text message: they belong to the prompt
/// being sent now, like leftover [images].
List<({String name, String text})> pendingFiles = [];

Future<List<llama.ChatMessage>> getHistory([String? addToSystem]) async {
  var system = prefs?.getString("system") ?? "You are a helpful assistant";
  if (prefs!.getBool("noMarkdown") ?? false) {
    system +=
        "\nYou must not use markdown or any other formatting language in any way!";
  }
  if (addToSystem != null) {
    system += "\n$addToSystem";
  }

  List<llama.ChatMessage> history = (prefs!.getBool("useSystem") ?? true)
      ? [llama.ChatMessage.system(system)]
      : [];
  images = [];
  pendingFiles = [];
  // `messages` is newest-first and a turn's images are inserted just before
  // its text, so walk it oldest-first: images then belong to the next text.
  // Images left over at the end belong to the prompt being sent now.
  for (final message in messages.reversed) {
    if (message is types.FileMessage) {
      pendingFiles.add(
          (name: message.name, text: '${message.metadata?['text'] ?? ''}'));
      continue;
    }
    final json = jsonDecode(jsonEncode(message));
    if (json["text"] != null) {
      history.add(llama.ChatMessage(
          role: (message.author.id == user.id)
              ? llama.MessageRole.user
              : llama.MessageRole.assistant,
          content: withAttachments(json["text"], pendingFiles),
          images: (images.isNotEmpty) ? images : null));
      images = [];
      pendingFiles = [];
    } else {
      var uri = json["uri"] as String;
      String content = (uri.startsWith("data:image/png;base64,"))
          ? uri.removePrefix("data:image/png;base64,")
          : base64.encode(await File(uri).readAsBytes());
      uri = uri.removePrefix("data:image/png;base64,");
      images.add(content);
    }
  }

  return history;
}

List getHistoryString([String? uuid]) {
  uuid ??= chatUuid!;
  List messages = [];
  for (var i = 0; i < chats.length; i++) {
    if (jsonDecode(chats[i])["uuid"] == uuid) {
      messages = jsonDecode(jsonDecode(chats[i])["messages"]);
      break;
    }
  }

  if (messages[0]["role"] == "system") {
    messages.removeAt(0);
  }
  for (var i = 0; i < messages.length; i++) {
    if (messages[i]["type"] == "image") {
      messages[i] = {
        "role": messages[i]["role"]!,
        "content": "<${messages[i]["role"]} inserted an image>"
      };
    } else if (messages[i]["type"] == "file") {
      messages[i] = {
        "role": "user",
        "content": "<user attached the file ${messages[i]["name"]}>"
      };
    }
  }

  return messages;
}

Future<String> getTitleAi(List history) async {
  final generated = await ollamaClient
.chat
      .create(
        request: llama.ChatRequest(
            model: model!,
            messages: [
              const llama.ChatMessage.system(
                      "Generate a three to six word title for the conversation provided by the user. If an object or person is very important in the conversation, put it in the title as well; keep the focus on the main subject. You must not put the assistant in the focus and you must not put the word 'assistant' in the title! Do preferably use title case. Use a formal tone, don't use dramatic words, like 'mystery' Use spaces between words, do not use camel case! You must not use markdown or any other formatting language! You must not use emojis or any other symbols! You must not use general clauses like 'assistance', 'help' or 'session' in your title! \n\n~~User Introduces Themselves~~ -> User Introduction\n~~User Asks for Help with a Problem~~ -> Problem Help\n~~User has a _**big**_ Problem~~ -> Big Problem"),
              llama.ChatMessage.user("```\n${jsonEncode(history)}\n```")
            ],
            keepAlive: keepAliveSetting),
      )
      .timeout(Duration(
          seconds:
              (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0)).round()));
  var title = generated.message?.content ?? "";
  title = title.replaceAll("\n", " ");

  var terms = [
    "\"",
    "'",
    "*",
    "_",
    ".",
    ",",
    "!",
    "?",
    ":",
    ";",
    "(",
    ")",
    "[",
    "]",
    "{",
    "}"
  ];
  for (var i = 0; i < terms.length; i++) {
    title = title.replaceAll(terms[i], "");
  }

  title = title.replaceAll(RegExp(r'<.*?>', dotAll: true), "");
  if (title.split(":").length == 2) {
    title = title.split(":")[1];
  }

  while (title.contains("  ")) {
    title = title.replaceAll("  ", " ");
  }
  return title.trim();
}

Future<void> setTitleAi(List history) async {
  try {
    var title = await getTitleAi(history);
    var tmp = List.of(chats);
    for (var i = 0; i < tmp.length; i++) {
      if (jsonDecode(chats[i])["uuid"] == chatUuid) {
        var tmp2 = jsonDecode(tmp[i]);
        tmp2["title"] = title;
        tmp[i] = jsonEncode(tmp2);
        break;
      }
    }
    saveChats(tmp);
  } catch (_) {}
}

Future<String> send(String value, BuildContext context, Function setState,
    {void Function(String currentText, bool done)? onStream,
    String? addToSystem}) async {
  selectionHaptic();
  setState(() {
    sendable = false;
  });

  if (host == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context)!.noHostSelected),
        showCloseIcon: true));
    if (onStream != null) {
      onStream("", true);
    }
    return "";
  }

  if (!chatAllowed || model == null) {
    if (model == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.noModelSelected),
          showCloseIcon: true));
    }
    if (onStream != null) {
      onStream("", true);
    }
    return "";
  }

  bool newChat = false;
  if (chatUuid == null) {
    newChat = true;
    chatUuid = const Uuid().v4();
    saveChats(List.of(chats).append([
      jsonEncode({
        "title": AppLocalizations.of(context)!.newChatTitle,
        "uuid": chatUuid,
        "messages": []
      })
    ]).toList());
  }

  var history = await getHistory(addToSystem);

  history.add(llama.ChatMessage.user(
      withAttachments(value.trim(), pendingFiles),
      images: (images.isNotEmpty) ? images : null));
  messages.insert(
      0,
      types.TextMessage(
          author: user, id: const Uuid().v4(), text: value.trim()));

  saveChat(chatUuid!, setState);

  setState(() {});
  chatAllowed = false;

  String text = "";
  String newId = const Uuid().v4();

  var hasFailedOver = false;
  String thinking = "";
  while (true) {
    // A failover retry starts the reasoning over on the new host.
    thinking = "";
    try {
      // ponytail: tool rounds are non-streaming; stream the final answer
      // too if waiting on long tool chains feels slow.
      final wantsWeb = prefs!.getBool("webTools") ?? false;
      final wantsMarket = prefs!.getBool("marketTools") ?? false;
      final wantsThinking = prefs!.getBool("think") ?? false;
      final wantsMcp =
          (prefs!.getBool("mcpTools") ?? false) && mcpServers.isNotEmpty;
      final capabilities =
          (wantsWeb || wantsMarket || wantsMcp || wantsThinking)
              ? await modelCapabilities(model!)
              : <String>{};
      // Sending tools or think to a model without the capability makes the
      // server reject the whole request, so both are gated per model.
      final canUseTools = capabilities.contains(capabilityTools);
      final toolSet = buildToolSet(httpClient,
          webApiKey: wantsWeb && canUseTools ? cloudApiKey : null,
          market: wantsMarket && canUseTools,
          mcp: wantsMcp && canUseTools
              ? allowedMcpConnections(
                  prefs!, await connectMcpServers(httpClient))
              : const [],
          userText: value);
      final useTools = toolSet.tools.isNotEmpty;
      final think =
          wantsThinking && capabilities.contains(capabilityThinking)
              ? const llama.ThinkValue.enabled(true)
              : null;
      if (!useTools &&
          (prefs!.getString("requestType") ?? "stream") == "stream") {
        final stream = ollamaClient.chat
            .createStream(
              request: llama.ChatRequest(
                  model: model!,
                  messages: history,
                  think: think,
                  keepAlive: keepAliveSetting),
            )
            .timeout(Duration(
                seconds: (30.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                    .round()));

        await for (final res in stream) {
          text += res.message?.content ?? "";
          thinking += res.message?.thinking ?? "";
          for (var i = 0; i < messages.length; i++) {
            if (messages[i].id == newId) {
              messages.removeAt(i);
              break;
            }
          }
          if (chatAllowed) return "";
          messages.insert(
              0,
              types.TextMessage(
                  author: assistant,
                  id: newId,
                  text: text,
                  metadata: thinkingMetadata(thinking)));
          //TODO: add functionality
          //
          // chatKey!.currentState!.scrollToMessage(messages[1].id,
          //     preferPosition: AutoScrollPosition.end);
          if (onStream != null) {
            onStream(text, false);
          }
          setState(() {});
          heavyHaptic();
        }
      } else {
        Future<llama.ChatMessage> callModel(
            List<llama.ChatMessage> turns) async {
          final response = await ollamaClient.chat
              .create(
                request: llama.ChatRequest(
                    model: model!,
                    messages: turns,
                    think: think,
                    tools: useTools ? toolSet.tools : null,
                    keepAlive: keepAliveSetting),
              )
              .timeout(Duration(
                  seconds:
                      (30.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                          .round()));
          // Keep content, thinking and tool calls so tool rounds can
          // replay the assistant turn faithfully.
          final message = response.message;
          return llama.ChatMessage.assistant(message?.content ?? "",
              thinking: message?.thinking, toolCalls: message?.toolCalls);
        }
        // A copy, so a failover retry does not resend this attempt's tool turns.
        final turns = List.of(history);
        final reply = useTools
            ? await runToolLoop(turns, callModel, toolSet.run)
            : (await callModel(turns).then((message) {
                turns.add(message);
                return message.content;
              }));
        thinking = turns.last.thinking ?? "";
        if (chatAllowed) return "";
        messages.insert(
            0,
            types.TextMessage(
                author: assistant,
                id: newId,
                text: reply,
                metadata: thinkingMetadata(thinking)));
        text = reply;
        setState(() {});
        heavyHaptic();
      }
      break;
    } catch (e) {
      if (!hasFailedOver && text.isEmpty && await failoverActiveHost(e)) {
        hasFailedOver = true;
        continue;
      }
      for (var i = 0; i < messages.length; i++) {
        if (messages[i].id == newId) {
          messages.removeAt(i);
          break;
        }
      }
      setState(() {
        chatAllowed = true;
        messages.removeAt(0);
        if (messages.isEmpty) {
          var tmp = List.of(chats);
          for (var i = 0; i < tmp.length; i++) {
            if (jsonDecode(chats[i])["uuid"] == chatUuid) {
              tmp.removeAt(i);
              saveChats(tmp);
              break;
            }
          }
          chatUuid = null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              AppLocalizations.of(context)!.settingsHostInvalid("timeout")),
          showCloseIcon: true));
      return "";
    }
  }
  //TODO: add functionality
  //
  // chatKey!.currentState!
  //     .scrollToMessage(messages[1].id, preferPosition: AutoScrollPosition.end);
  if ((prefs!.getString("requestType") ?? "stream") == "stream") {
    if (onStream != null) {
      onStream(text, true);
    }
  }
  saveChat(chatUuid!, setState);

  if (newChat && (prefs!.getBool("generateTitles") ?? true)) {
    void setTitle() async {
      await setTitleAi(getHistoryString());
      setState(() {});
    }

    setTitle();
  }

  setState(() {});
  chatAllowed = true;
  return text;
}

/// Message metadata carrying the model's reasoning, or null when there is
/// none, so plain replies stay unchanged.
Map<String, dynamic>? thinkingMetadata(String thinking) =>
    thinking.trim().isEmpty ? null : {"thinking": thinking};

/// Asks again for the latest reply: drops it and its prompt, then resends
/// the prompt. Files attached to that prompt stay pending, so they go with
/// the new request too.
Future<void> regenerateLastReply(
    BuildContext context, Function setState) async {
  if (!chatAllowed || messages.length < 2) return;
  final reply = messages[0];
  final prompt = messages[1];
  if (reply.author.id != assistant.id ||
      prompt is! types.TextMessage ||
      prompt.author.id != user.id) {
    return;
  }
  messages.removeRange(0, 2);
  setState(() {});
  await send(prompt.text, context, setState);
}
