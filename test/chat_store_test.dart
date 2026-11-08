import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/worker/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('chats'));
  tearDown(() async => dir.delete(recursive: true));

  test('should migrate prefs chats to file and drop prefs copy', () async {
    SharedPreferences.setMockInitialValues({
      'chats': [
        jsonEncode({'uuid': 'a'})
      ]
    });
    final prefs = await SharedPreferences.getInstance();
    await loadChats(prefs, dir);
    expect(chats.length, 1);
    expect(prefs.getStringList('chats'), isNull);
    expect(File('${dir.path}/chats.json').existsSync(), isTrue);
  });

  test('should persist saves and reload them from file', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await loadChats(prefs, dir);
    await saveChats(['one', 'two']);
    chats = [];
    await loadChats(prefs, dir);
    expect(chats, ['one', 'two']);
  });

  test('should keep last save when saves overlap', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await loadChats(prefs, dir);
    await Future.wait([
      for (var i = 0; i < 20; i++) saveChats(['v$i'])
    ]);
    await loadChats(prefs, dir);
    expect(chats, ['v19']);
  });

  test('should keep chats in prefs when no data directory (web)', () async {
    SharedPreferences.setMockInitialValues({
      'chats': ['web']
    });
    final prefs = await SharedPreferences.getInstance();
    await loadChats(prefs, null);
    await saveChats(['web', 'more']);
    expect(prefs.getStringList('chats'), ['web', 'more']);
  });

  test('should prefer existing file over leftover prefs', () async {
    File('${dir.path}/chats.json').writeAsStringSync(jsonEncode(['file']));
    SharedPreferences.setMockInitialValues({
      'chats': ['prefs']
    });
    await loadChats(await SharedPreferences.getInstance(), dir);
    expect(chats, ['file']);
  });
}
