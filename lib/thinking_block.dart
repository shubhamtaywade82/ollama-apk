import 'package:flutter/material.dart';

import 'package:hearth/l10n/gen/app_localizations.dart';

/// Reasoning text kept on an assistant message, or null if it has none.
String? thinkingOf(Map<String, dynamic>? metadata) {
  final thinking = metadata?['thinking'];
  return thinking is String && thinking.trim().isNotEmpty ? thinking : null;
}

/// Collapsible reasoning shown above an answer. Open while the model is
/// still thinking, collapsed once the answer starts, unless the user has
/// toggled it.
class ThinkingBlock extends StatefulWidget {
  final String thinking;
  final bool isAnswering;

  const ThinkingBlock(
      {super.key, required this.thinking, required this.isAnswering});

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool? userExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isExpanded = userExpanded ?? !widget.isAnswering;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => setState(() => userExpanded = !isExpanded),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.psychology_alt_rounded, size: 16, color: muted),
          const SizedBox(width: 6),
          Text(widget.isAnswering ? l10n.thinkingDone : l10n.thinkingActive,
              style: TextStyle(color: muted, fontStyle: FontStyle.italic)),
          Icon(
              isExpanded
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 18,
              color: muted),
        ]),
      ),
      if (isExpanded)
        Container(
          margin: const EdgeInsets.only(top: 6, bottom: 4),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
              border: Border(left: BorderSide(color: muted, width: 2))),
          child: Text(widget.thinking,
              style: TextStyle(color: muted, fontSize: 13)),
        ),
      const SizedBox(height: 8),
    ]);
  }
}
