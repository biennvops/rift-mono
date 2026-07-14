import 'package:app_flutter/src/file_transfer/file_storage.dart' as storage;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeIncomingFileName', () {
    test('falls back for dot-only names', () {
      expect(storage.sanitizeIncomingFileName('.'), 'incoming.bin');
      expect(storage.sanitizeIncomingFileName('..'), 'incoming.bin');
      expect(storage.sanitizeIncomingFileName('...'), 'incoming.bin');
    });

    test('drops path components before sanitizing', () {
      expect(storage.sanitizeIncomingFileName('../../evil.txt'), 'evil.txt');
      expect(storage.sanitizeIncomingFileName(r'..\..\evil.txt'), 'evil.txt');
    });

    test('replaces platform-illegal characters', () {
      expect(
        storage.sanitizeIncomingFileName('bad<name>?.txt'),
        'bad_name__.txt',
      );
    });
  });
}
