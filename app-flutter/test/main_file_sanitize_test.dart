import 'package:app_flutter/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeIncomingFileName', () {
    test('falls back for dot-only names', () {
      expect(app.sanitizeIncomingFileName('.'), 'incoming.bin');
      expect(app.sanitizeIncomingFileName('..'), 'incoming.bin');
      expect(app.sanitizeIncomingFileName('...'), 'incoming.bin');
    });

    test('drops path components before sanitizing', () {
      expect(app.sanitizeIncomingFileName('../../evil.txt'), 'evil.txt');
      expect(app.sanitizeIncomingFileName(r'..\..\evil.txt'), 'evil.txt');
    });

    test('replaces platform-illegal characters', () {
      expect(
        app.sanitizeIncomingFileName('bad<name>?.txt'),
        'bad_name__.txt',
      );
    });
  });
}
