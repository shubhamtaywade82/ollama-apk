import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:ollama_app/l10n/gen/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:read_pdf_text/read_pdf_text.dart';
import 'package:uuid/uuid.dart';

import '../main.dart' show messages, user;

// Each attachment rides in the prompt. ~60k characters is about 15k tokens:
// big enough for most documents, small enough not to evict the conversation
// from a typical 32k context window.
const maxAttachmentChars = 60000;

class AttachmentException implements Exception {
  final String message;

  const AttachmentException(this.message);

  @override
  String toString() => message;
}

typedef PdfTextExtractor = Future<String> Function(Uint8List bytes);

/// Text of an attached file: PDF text layer, or the file decoded as UTF-8.
/// Throws [AttachmentException] for binaries and PDFs with no text layer.
Future<String> extractAttachmentText(String name, Uint8List bytes,
    {PdfTextExtractor extractPdf = extractPdfText}) async {
  final isPdf = name.toLowerCase().endsWith('.pdf');
  final text = isPdf ? await extractPdf(bytes) : _decodeText(name, bytes);
  if (text.trim().isEmpty) {
    throw AttachmentException(
        isPdf ? '$name has no text layer (scanned PDF?)' : '$name is empty');
  }
  return text;
}

String _decodeText(String name, Uint8List bytes) {
  final sample = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
  // A NUL byte almost never appears in text and almost always in binaries.
  if (sample.contains(0)) {
    throw AttachmentException('$name is not a text file');
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Future<String> extractPdfText(Uint8List bytes) async {
  // The PDF plugin reads from a path, so the picked bytes go through a
  // temp file that is always removed.
  final dir = await getTemporaryDirectory();
  final file = File(
      '${dir.path}/attachment-${DateTime.now().microsecondsSinceEpoch}.pdf');
  await file.writeAsBytes(bytes, flush: true);
  try {
    return await ReadPdfText.getPDFtext(file.path);
  } on MissingPluginException {
    throw const AttachmentException(
        'PDF text extraction is only available on Android and iOS');
  } on PlatformException catch (e) {
    throw AttachmentException('Could not read PDF: ${e.message}');
  } finally {
    if (await file.exists()) await file.delete();
  }
}

/// Clips [text] to [maxAttachmentChars], saying so, so the model knows the
/// rest of the file exists.
String clipAttachmentText(String text) => text.length <= maxAttachmentChars
    ? text
    : '${text.substring(0, maxAttachmentChars)}\n'
        '[... truncated: ${text.length - maxAttachmentChars} more characters]';

/// [prompt] with each attached file prepended as a delimited block.
String withAttachments(
    String prompt, List<({String name, String text})> files) {
  if (files.isEmpty) return prompt;
  final blocks = files.map(
      (f) => '<attached_file name="${f.name}">\n${f.text}\n</attached_file>');
  return '${blocks.join('\n\n')}\n\n$prompt';
}

/// Lets the user pick a document, extracts its text, and adds it to the
/// pending message as a file bubble. Errors are shown, not thrown.
Future<void> attachFileToChat(
    BuildContext context, void Function(void Function()) setState) async {
  // No extension filter: Android maps filters to MIME types and drops
  // unknown ones (.pine, .dart, …). Binaries are rejected after reading.
  final picked = await FilePicker.pickFiles(withData: true);
  final file = picked?.files.firstOrNull;
  final bytes = file?.bytes;
  if (file == null || bytes == null) return;
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  // PDFs and large files take a moment; say something is happening.
  messenger.showSnackBar(SnackBar(
      content: Text(l10n.attachFileReading(file.name)),
      duration: const Duration(seconds: 30)));
  try {
    final fullText = await extractAttachmentText(file.name, bytes);
    final text = clipAttachmentText(fullText);
    messages.insert(
        0,
        types.FileMessage(
            author: user,
            id: const Uuid().v4(),
            createdAt: DateTime.now().millisecondsSinceEpoch,
            name: file.name,
            size: file.size,
            uri: file.name,
            metadata: {'text': text}));
    setState(() {});
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(attachedNotice(l10n, file.name, fullText.length)),
        showCloseIcon: true,
        duration: const Duration(seconds: 8)));
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(l10n.attachFileFailed('$e')), showCloseIcon: true));
  }
}

/// What the user is told after attaching: that the file goes with the next
/// message, and how much of it, when it is too long to send whole.
String attachedNotice(AppLocalizations l10n, String name, int totalChars) {
  if (totalChars <= maxAttachmentChars) return l10n.attachFileReady(name);
  final percent = (maxAttachmentChars * 100 / totalChars).floor();
  return l10n.attachFileTruncated(name, percent);
}

/// The file waiting to go with the next message, if any: attachments are
/// inserted newest-first, so it sits at the front of [messages].
String? pendingAttachmentName() {
  final latest = messages.firstOrNull;
  return latest is types.FileMessage ? latest.name : null;
}
