import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/l10n/gen/app_localizations.dart';
import 'package:hearth/main.dart' as app;
import 'package:hearth/message_actions.dart';
import 'package:hearth/worker/sender.dart';
import 'package:shared_preferences/shared_preferences.dart';

final reply =
    types.TextMessage(author: app.assistant, id: 'a2', text: 'Answer');
final older = types.TextMessage(author: app.assistant, id: 'a1', text: 'Old');
final prompt = types.TextMessage(author: app.user, id: 'u2', text: 'Question');

Future<void> pumpActions(WidgetTester tester, types.TextMessage message) =>
    tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: MessageActions(message: message, setChatState: (_) {}))));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    app.chatAllowed = true;
    app.messages = [reply, prompt, older];
  });

  testWidgets('should copy the reply text to the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await pumpActions(tester, reply);
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    expect(copied, 'Answer');
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });

  testWidgets('should offer regenerate only on the latest reply',
      (tester) async {
    await pumpActions(tester, reply);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    await pumpActions(tester, older);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
  });

  testWidgets('should hide regenerate while a reply is streaming',
      (tester) async {
    app.chatAllowed = false;
    await pumpActions(tester, reply);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
  });

  testWidgets('should leave the chat alone when the last turn is not a reply',
      (tester) async {
    app.messages = [prompt, older];
    await pumpActions(tester, reply);
    final context = tester.element(find.byType(MessageActions));
    await regenerateLastReply(context, (_) {});
    expect(app.messages.map((m) => m.id), ['u2', 'a1']);
  });
}
