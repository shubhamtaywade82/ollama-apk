import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/l10n/gen/app_localizations.dart';
import 'package:ollama_app/main.dart' as app;
import 'package:ollama_app/worker/attachments.dart';
import 'package:ollama_app/worker/chat_store.dart';
import 'package:ollama_app/worker/sender.dart';
import 'package:ollama_app/worker/setter.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

types.FileMessage fileMessage(String name, String text) => types.FileMessage(
    author: app.user,
    id: name,
    name: name,
    size: text.length,
    uri: name,
    metadata: {'text': text});

void main() {
  feedbackTests();
  group('extractAttachmentText', () {
    test('should decode text and code files as UTF-8', () async {
      expect(
          await extractAttachmentText('notes.md', bytesOf('# Hi ✓')), '# Hi ✓');
    });

    test('should reject binaries and empty files', () async {
      final binary = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 0, 0, 1]);
      await expectLater(extractAttachmentText('report.docx', binary),
          throwsA(isA<AttachmentException>()));
      await expectLater(extractAttachmentText('blank.txt', bytesOf('  \n')),
          throwsA(isA<AttachmentException>()));
    });

    test('should route PDFs to the PDF extractor', () async {
      final text = await extractAttachmentText('Paper.PDF', bytesOf('%PDF'),
          extractPdf: (_) async => 'page one');
      expect(text, 'page one');
    });

    test('should explain a PDF with no text layer', () async {
      await expectLater(
          extractAttachmentText('scan.pdf', bytesOf('%PDF'),
              extractPdf: (_) async => '\n\n'),
          throwsA(isA<AttachmentException>()
              .having((e) => e.message, 'message', contains('no text layer'))));
    });
  });

  test('should clip long files and say how much was cut', () {
    final long = 'x' * (maxAttachmentChars + 10);
    final clipped = clipAttachmentText(long);
    expect(clipped, startsWith('x' * maxAttachmentChars));
    expect(clipped, endsWith('[... truncated: 10 more characters]'));
    expect(clipAttachmentText('short'), 'short');
  });

  test('should prepend files to the prompt as delimited blocks', () {
    expect(withAttachments('Summarize', []), 'Summarize');
    expect(
        withAttachments('Summarize', [(name: 'a.txt', text: 'alpha')]),
        '<attached_file name="a.txt">\nalpha\n</attached_file>\n\n'
        'Summarize');
  });

  group('history with attachments', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({'useSystem': false});
      app.prefs = await SharedPreferences.getInstance();
    });

    test('should attach a file to the message sent after it', () async {
      app.messages = [
        types.TextMessage(author: app.assistant, id: 'a1', text: 'Done'),
        types.TextMessage(author: app.user, id: 'u1', text: 'Summarize'),
        fileMessage('report.txt', 'quarterly numbers'),
      ];
      final history = await getHistory();
      expect(history.first.content,
          contains('<attached_file name="report.txt">\nquarterly numbers'));
      expect(history.first.content, endsWith('Summarize'));
      expect(history.last.content, 'Done');
      expect(pendingFiles, isEmpty);
    });

    test('should leave newly attached files pending for the next prompt',
        () async {
      app.messages = [
        fileMessage('new.csv', 'a,b'),
        types.TextMessage(author: app.user, id: 'u1', text: 'Hello'),
      ];
      final history = await getHistory();
      expect(history.single.content, 'Hello');
      expect(pendingFiles.single.name, 'new.csv');
    });
  });

  test('should keep attached files when a chat is saved and reloaded',
      () async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await loadChats(app.prefs!, null);
    await saveChats([
      jsonEncode({'title': 't', 'uuid': 'c1', 'messages': []})
    ]);
    app.chatUuid = 'c1';
    app.messages = [
      types.TextMessage(author: app.user, id: 'u', text: 'Read this'),
      fileMessage('doc.md', '# Doc'),
    ];
    saveChat('c1', (_) {});
    await Future<void>.delayed(Duration.zero);
    app.messages = [];
    loadChat('c1', (_) {});
    final file = app.messages.whereType<types.FileMessage>().single;
    expect(file.name, 'doc.md');
    expect(file.metadata?['text'], '# Doc');
    expect(app.messages.first, isA<types.TextMessage>());
  });
}

void feedbackTests() {
  test('should say how much of a long file will be sent', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(attachedNotice(l10n, 'a.md', 100), contains('next message'));
    expect(attachedNotice(l10n, 'docs.md', 415000),
        contains('only the first 14%'));
  });

  test('should report the file waiting for the next message', () {
    app.messages = [fileMessage('docs.md', 'x')];
    expect(pendingAttachmentName(), 'docs.md');
    app.messages = [
      types.TextMessage(author: app.user, id: 'u', text: 'hi'),
      fileMessage('old.md', 'x'),
    ];
    expect(pendingAttachmentName(), isNull);
  });
}
