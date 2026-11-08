import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'main.dart';
import 'worker/haptic.dart';
import 'worker/sender.dart';

import 'package:hearth/l10n/gen/app_localizations.dart';

/// Copy, read aloud and (on the latest reply) regenerate, shown under a
/// finished assistant reply.
class MessageActions extends StatelessWidget {
  final types.TextMessage message;
  final Function setChatState;

  const MessageActions(
      {super.key, required this.message, required this.setChatState});

  bool get isLatest => messages.isNotEmpty && messages.first.id == message.id;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget action(IconData icon, String tooltip, VoidCallback onPressed) =>
        IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            color: color,
            tooltip: tooltip,
            onPressed: () {
              selectionHaptic();
              onPressed();
            },
            icon: Icon(icon));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      action(Icons.copy_rounded, l10n.messageCopy, () async {
        await Clipboard.setData(ClipboardData(text: message.text));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.messageCopied), showCloseIcon: true));
      }),
      action(Icons.volume_up_rounded, l10n.messageReadAloud, () async {
        await voice.stop();
        await voice.setLanguage((prefs!.getString("voiceLanguage") ?? "en_US")
            .replaceAll("_", "-"));
        await voice.speak(message.text);
      }),
      if (isLatest && chatAllowed)
        action(Icons.refresh_rounded, l10n.messageRegenerate,
            () => regenerateLastReply(context, setChatState)),
    ]);
  }
}
