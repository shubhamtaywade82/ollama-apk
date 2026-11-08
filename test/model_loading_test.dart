import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/main.dart' as app;
import 'package:hearth/worker/setter.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  capabilityTests();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    // Port 1 refuses connections, so metadata calls fail fast.
    app.host = 'http://127.0.0.1:1';
  });

  test('should detect clip models without a metadata call', () async {
    const entry = llama.ModelSummary(
        model: 'llava:7b', details: llama.ModelDetails(families: ['clip']));
    expect(await supportsVisionInput(entry), isTrue);
  });

  test('should treat failed metadata as no vision instead of throwing',
      () async {
    const entry = llama.ModelSummary(model: 'llama3:8b');
    expect(await supportsVisionInput(entry), isFalse);
  });
}

void capabilityTests() {
  group('modelCapabilities', () {
    late HttpServer server;
    var showCalls = 0;
    var failing = false;

    setUp(() async {
      showCalls = 0;
      failing = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        showCalls++;
        request.response.headers.contentType = ContentType.json;
        if (failing) {
          request.response.statusCode = 500;
        } else {
          request.response
              .write('{"capabilities":["completion","tools","thinking"]}');
        }
        await request.response.close();
      });
      SharedPreferences.setMockInitialValues({});
      app.prefs = await SharedPreferences.getInstance();
      app.host = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() => server.close(force: true));

    test('should read capabilities once and cache them', () async {
      final first = await modelCapabilities('qwen3:8b');
      await modelCapabilities('qwen3:8b');
      expect(first, containsAll([capabilityTools, capabilityThinking]));
      expect(showCalls, 1);
    });

    test('should return empty and not cache when the lookup fails', () async {
      failing = true;
      expect(await modelCapabilities('flaky:1b'), isEmpty);
      failing = false;
      expect(await modelCapabilities('flaky:1b'), isNotEmpty);
    });
  });
}
