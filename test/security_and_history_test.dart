import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/main.dart' as app;
import 'package:ollama_app/worker/clients.dart';
import 'package:ollama_app/worker/hosts.dart';
import 'package:ollama_app/worker/sender.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;
import 'package:shared_preferences/shared_preferences.dart';

types.TextMessage text(types.User author, String body) =>
    types.TextMessage(author: author, id: body, text: body);

types.ImageMessage image(String base64) => types.ImageMessage(
    author: app.user,
    id: base64,
    name: 'i.png',
    size: 1,
    uri: 'data:image/png;base64,$base64');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'useSystem': false});
    app.prefs = await SharedPreferences.getInstance();
  });

  group('credential isolation', () {
    test('should send cloud key only to ollama.com', () async {
      cloudApiKey = 'secret';
      app.host = 'http://192.168.1.5:11434';
      expect(ollamaClientHeaders()['Authorization'], isNull);
      app.host = cloudOrigin;
      expect(ollamaClientHeaders()['Authorization'], 'Bearer secret');
    });

    test('should upgrade http cloud url to https', () {
      expect(normalizeHostUrl('http://ollama.com/'), 'https://ollama.com');
      expect(normalizeHostUrl('ollama.com'), 'https://ollama.com');
      expect(
          normalizeHostUrl('http://10.0.0.2:11434/'), 'http://10.0.0.2:11434');
    });

    test('should not attach a key to non-cloud host headers', () {
      cloudApiKey = 'k';
      const local = OllamaHost(name: 'l', url: 'http://10.0.0.2:11434');
      const cloud = OllamaHost(name: 'c', url: cloudOrigin);
      expect(local.headers, isEmpty);
      expect(cloud.headers['Authorization'], 'Bearer k');
    });
  });

  test('should move plaintext key into secure storage on load', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'apiKey': 'old'});
    final prefs = await SharedPreferences.getInstance();
    await loadCloudApiKey(prefs);
    expect(cloudApiKey, 'old');
    expect(prefs.getString('apiKey'), isNull);
    await saveCloudApiKey('');
    await loadCloudApiKey(prefs);
    expect(cloudApiKey, isNull);
  });

  group('history reconstruction', () {
    test('should map prior replies to assistant role in order', () async {
      app.messages = [
        text(app.assistant, 'a1'),
        text(app.user, 'u1'),
      ];
      final history = await getHistory();
      expect(history.map((m) => m.role),
          [llama.MessageRole.user, llama.MessageRole.assistant]);
      expect(history.map((m) => m.content), ['u1', 'a1']);
    });

    test('should attach images to their own turn, not the previous reply',
        () async {
      app.messages = [
        image('NEW'),
        text(app.assistant, 'a1'),
        text(app.user, 'u1'),
        image('OLD'),
      ];
      final history = await getHistory();
      expect(history[0].images, ['OLD']);
      expect(history[1].images, isNull);
      expect(images, ['NEW'], reason: 'pending images go to the new prompt');
    });
  });
}
