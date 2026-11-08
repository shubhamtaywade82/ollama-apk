import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/l10n/gen/app_localizations.dart';
import 'package:ollama_app/main.dart' as app;
import 'package:ollama_app/settings/hosts.dart';
import 'package:ollama_app/worker/hosts.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpScreen(WidgetTester tester) =>
    tester.pumpWidget(const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ScreenSettingsHosts()));

void main() {
  testWidgets('should show empty state when no hosts saved', (tester) async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await pumpScreen(tester);
    expect(find.textContaining('No hosts yet'), findsOneWidget);
  });

  testWidgets('should list saved hosts and mark the active one',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await saveHosts(app.prefs!, const [
      OllamaHost(name: 'laptop', url: 'http://10.0.0.2:11434'),
      OllamaHost(name: 'router', url: 'http://10.0.0.2:8080'),
    ]);
    app.host = 'http://10.0.0.2:8080';
    await pumpScreen(tester);
    expect(find.text('laptop'), findsOneWidget);
    expect(find.text('router'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('should reject invalid url in add dialog', (tester) async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await pumpScreen(tester);
    await tester.tap(find.text('Add host'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'not a url');
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pump();
    expect(find.textContaining('full URL'), findsOneWidget);
  });
}
