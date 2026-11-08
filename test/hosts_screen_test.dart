import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/l10n/gen/app_localizations.dart';
import 'package:hearth/main.dart' as app;
import 'package:hearth/settings/hosts.dart';
import 'package:hearth/worker/hosts.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpScreen(WidgetTester tester) =>
    tester.pumpWidget(const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ScreenSettingsHosts()));

void main() {
  activeHostRemovalTests();
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

  testWidgets('should warn about localhost on a phone and report test result',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await pumpScreen(tester);
    await tester.tap(find.text('Add host'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).at(1), 'http://localhost:11434');
    await tester.pump();
    expect(
        find.textContaining('localhost is the phone itself'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), 'http://127.0.0.1:1');
    await tester.tap(find.text('Test connection'));
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 1)));
    await tester.pump();
    expect(find.textContaining('Failed:'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

void activeHostRemovalTests() {
  Future<void> swipeAway(WidgetTester tester, String name) async {
    await tester.drag(find.text(name), const Offset(-600, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('should hand over to the next local host when active is removed',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await saveHosts(app.prefs!, const [
      OllamaHost(name: 'laptop', url: 'http://10.0.0.2:11434'),
      OllamaHost(name: 'cloud', url: 'https://ollama.com'),
      OllamaHost(name: 'router', url: 'http://10.0.0.2:8080'),
    ]);
    app.host = 'http://10.0.0.2:11434';
    await pumpScreen(tester);
    await swipeAway(tester, 'laptop');
    expect(app.host, 'http://10.0.0.2:8080');
    expect(app.prefs!.getString('host'), 'http://10.0.0.2:8080');
  });

  testWidgets('should disconnect rather than switch a local chat to Cloud',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    await saveHosts(app.prefs!, const [
      OllamaHost(name: 'laptop', url: 'http://10.0.0.2:11434'),
      OllamaHost(name: 'cloud', url: 'https://ollama.com'),
    ]);
    app.host = 'http://10.0.0.2:11434';
    await app.prefs!.setString('host', 'http://10.0.0.2:11434');
    await pumpScreen(tester);
    await swipeAway(tester, 'laptop');
    expect(app.host, isNull);
    expect(app.prefs!.getString('host'), isNull);
  });
}
