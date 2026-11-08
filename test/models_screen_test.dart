import 'dart:io';

import 'package:hearth/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/settings/models.dart';

void main() {
  inventoryTests();
  test('should format byte sizes with binary units', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(4920000000), '4.6 GB');
  });
}

void inventoryTests() {
  test('should list installed models when running-model lookup fails',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/api/tags') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
            '{"models":[{"model":"llama3:8b","name":"llama3:8b","size":42}]}');
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    SharedPreferences.setMockInitialValues({});
    app.prefs = await SharedPreferences.getInstance();
    app.host = 'http://127.0.0.1:${server.port}';

    final (installed, loaded) = await loadInventory();
    expect(installed.single.model, 'llama3:8b');
    expect(loaded, isEmpty);
  });
}
