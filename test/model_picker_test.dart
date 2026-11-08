import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/l10n/gen/app_localizations.dart';
import 'package:hearth/main.dart' as app;
import 'package:hearth/worker/setter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tags = '''{"models":[
  {"model":"llama3:8b","name":"llama3:8b","size":4920000000,
   "details":{"parameter_size":"8B","quantization_level":"Q4_K_M"}},
  {"model":"qwen3:8b","name":"qwen3:8b","size":5200000000,
   "details":{"parameter_size":"8B","quantization_level":"Q4_K_M"}},
  {"model":"gemma3:4b","name":"gemma3:4b","size":3300000000,
   "details":{"parameter_size":"4B","quantization_level":"Q4_K_M"}}
]}''';

Future<HttpServer> fakeOllama() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(request.uri.path == '/api/tags'
        ? tags
        : '{"capabilities":["completion"]}');
    await request.response.close();
  });
  return server;
}

Widget launcher() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
            body: TextButton(
                onPressed: () => setModel(context, setState),
                child: const Text('open')))));

Future<void> openPicker(WidgetTester tester) async {
  // A phone-sized screen, so the picker opens as a bottom sheet (wider
  // windows get the desktop dialog).
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(launcher());
  await tester.tap(find.text('open'));
  await tester.pump(); // draw the sheet so the loader can update it
  // The model list loads over real loopback HTTP, which needs real time.
  // Alternate real waits with single frames: jumping the fake clock (as
  // pumpAndSettle does) would fire the loader's 10 s timeout first.
  for (var i = 0; i < 20 && find.byType(ListTile).evaluate().isEmpty; i++) {
    await tester
        .runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
  await tester.pumpAndSettle(); // finish the sheet's opening animation
}

/// dart:io keeps the loopback connection alive on a 15 s idle timer, which
/// the fake test clock must pass before the test may end.
Future<void> settleHttpTimers(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 30));

void main() {
  late HttpServer server;

  setUp(() async {
    // Widget tests answer all HTTP with 400 unless the override is removed.
    HttpOverrides.global = null;
    server = await fakeOllama();
    SharedPreferences.setMockInitialValues({'preloadModel': false});
    app.prefs = await SharedPreferences.getInstance();
    app.host = 'http://127.0.0.1:${server.port}';
    app.model = 'qwen3:8b';
    app.chatAllowed = true;
  });

  tearDown(() => server.close(force: true));

  testWidgets('should list models as rows with details and a check',
      (tester) async {
    await openPicker(tester);
    expect(find.byType(ListTile), findsNWidgets(4), reason: '3 models + Add');
    expect(find.textContaining('8B  ·  Q4_K_M  ·  4.6 GB'), findsOneWidget);
    final selected = tester.widget<ListTile>(find.ancestor(
        of: find.text('qwen3:8b', findRichText: true),
        matching: find.byType(ListTile)));
    expect(selected.selected, isTrue);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await settleHttpTimers(tester);
  });

  testWidgets('should select a model with one tap and close the picker',
      (tester) async {
    await openPicker(tester);
    await tester.tap(find.text('gemma3:4b', findRichText: true));
    await tester.pumpAndSettle();
    expect(app.model, 'gemma3:4b');
    expect(app.prefs!.getString('model'), 'gemma3:4b');
    expect(find.byType(ListTile), findsNothing);
    await settleHttpTimers(tester);
  });
}
