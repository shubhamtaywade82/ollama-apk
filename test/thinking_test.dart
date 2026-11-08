import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/l10n/gen/app_localizations.dart';
import 'package:ollama_app/main.dart' as app;
import 'package:ollama_app/thinking_block.dart';
import 'package:ollama_app/worker/chat_store.dart';
import 'package:ollama_app/worker/sender.dart';
import 'package:ollama_app/worker/setter.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child)));

void main() {
  test('should only attach metadata when there is reasoning', () {
    expect(thinkingMetadata('  '), isNull);
    expect(thinkingOf(thinkingMetadata('step 1')), 'step 1');
    expect(thinkingOf(null), isNull);
  });

  testWidgets('should show reasoning while thinking and collapse on answer',
      (tester) async {
    await pump(
        tester, const ThinkingBlock(thinking: 'step 1', isAnswering: false));
    expect(find.text('Thinking…'), findsOneWidget);
    expect(find.text('step 1'), findsOneWidget);

    await pump(
        tester, const ThinkingBlock(thinking: 'step 1', isAnswering: true));
    expect(find.text('Thought process'), findsOneWidget);
    expect(find.text('step 1'), findsNothing);

    await tester.tap(find.text('Thought process'));
    await tester.pump();
    expect(find.text('step 1'), findsOneWidget);
  });

  test('should keep reasoning when a chat is saved and reloaded', () async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await loadChats(app.prefs!, null);
    await saveChats([
      jsonEncode({'title': 't', 'uuid': 'c1', 'messages': []})
    ]);
    app.chatUuid = 'c1';
    app.messages = [
      types.TextMessage(
          author: app.assistant,
          id: 'a',
          text: 'answer',
          metadata: thinkingMetadata('because')),
      types.TextMessage(author: app.user, id: 'u', text: 'why?'),
    ];
    saveChat('c1', (_) {});
    await Future<void>.delayed(Duration.zero);
    app.messages = [];
    loadChat('c1', (_) {});
    final reloaded = app.messages.whereType<types.TextMessage>().toList();
    expect(reloaded.map((m) => m.text), ['answer', 'why?']);
    expect(thinkingOf(reloaded.first.metadata), 'because');
    expect(reloaded.last.metadata, isNull);
  });
}
