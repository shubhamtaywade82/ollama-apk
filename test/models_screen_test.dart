import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/settings/models.dart';

void main() {
  test('should format byte sizes with binary units', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(4920000000), '4.6 GB');
  });
}
