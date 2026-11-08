import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'chats';
const _fileName = 'chats.json';

/// Encoded chats, newest first, in the same string-per-chat shape the UI
/// already uses. Read synchronously from memory; persisted asynchronously.
List<String> chats = [];

SharedPreferences? _prefs;
File? _file;
Future<void> _lastWrite = Future.value();

// ponytail: whole-file rewrite on every save, like the old prefs blob but
// off the preferences store. Move to SQLite behind loadChats/saveChats when
// chat volume makes saves visibly slow.
/// Loads chats from [dataDir], migrating them out of preferences once.
/// With no [dataDir] (web), chats stay in preferences.
Future<void> loadChats(SharedPreferences prefs, Directory? dataDir) async {
  _prefs = prefs;
  _file = dataDir == null ? null : File('${dataDir.path}/$_fileName');
  final file = _file;
  if (file != null && await file.exists()) {
    chats = (jsonDecode(await file.readAsString()) as List).cast<String>();
    return;
  }
  chats = prefs.getStringList(_prefsKey) ?? [];
  if (file == null) return;
  await _persist();
  // Only drop the old copy once the file is safely written.
  await prefs.remove(_prefsKey);
}

/// Replaces all chats in memory immediately and on disk in save order.
Future<void> saveChats(List<String> updated) {
  chats = List.of(updated);
  // Chain writes so two saves never interleave on the temp file; a failed
  // write must not block later ones.
  _lastWrite = _lastWrite.catchError((_) {}).then((_) => _persist());
  return _lastWrite;
}

Future<void> _persist() async {
  final file = _file;
  if (file == null) {
    await _prefs?.setStringList(_prefsKey, chats);
    return;
  }
  // Write-then-rename so a crash mid-write never leaves a truncated file.
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(jsonEncode(chats), flush: true);
  await temp.rename(file.path);
}
