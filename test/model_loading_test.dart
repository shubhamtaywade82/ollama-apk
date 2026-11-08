import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/main.dart' as app;
import 'package:ollama_app/worker/setter.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    // Port 1 refuses connections, so metadata calls fail fast.
    app.host = 'http://127.0.0.1:1';
  });

  test('should detect clip models without a metadata call', () async {
    const entry = llama.Model(
        model: 'llava:7b', details: llama.ModelDetails(families: ['clip']));
    expect(await supportsVisionInput(entry), isTrue);
  });

  test('should treat failed metadata as no vision instead of throwing',
      () async {
    const entry = llama.Model(model: 'llama3:8b');
    expect(await supportsVisionInput(entry), isFalse);
  });
}
