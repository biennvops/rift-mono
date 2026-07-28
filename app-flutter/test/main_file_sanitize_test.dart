import 'package:app_flutter/src/file_transfer/file_storage.dart' as storage;
import 'package:app_flutter/src/platform/android_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Android download bridge', () {
    const channel = MethodChannel('rift/android/shell');

    tearDown(() async {
      AndroidShell.debugIsAndroidOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('prepares staging and publishes into public Downloads', () async {
      final calls = <MethodCall>[];
      AndroidShell.debugIsAndroidOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'prepareIncomingDownload') {
          return {
            'stagingPath': '/private/incoming.part',
            'displayPath': 'Downloads/report.pdf',
          };
        }
        if (call.method == 'publishIncomingDownload') {
          return {
            'contentUri': 'content://downloads/report',
            'displayPath': 'Downloads/report.pdf',
          };
        }
        return null;
      });

      final prepared = await AndroidShell.prepareIncomingDownload('report.pdf');
      final published = await AndroidShell.publishIncomingDownload(
        stagingPath: prepared!['stagingPath'].toString(),
        fileName: 'report.pdf',
        mediaType: 'application/pdf',
      );

      expect(prepared['displayPath'], 'Downloads/report.pdf');
      expect(published!['contentUri'], 'content://downloads/report');
      expect(calls.map((call) => call.method), [
        'prepareIncomingDownload',
        'publishIncomingDownload',
      ]);
    });
  });

  group('Linux Downloads path selection', () {
    test('prefers a valid XDG Downloads path', () {
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: '/home/user/Transfers',
          homePath: '/home/user',
        ),
        '/home/user/Transfers',
      );
    });

    test('falls back to HOME when XDG resolution is unavailable', () {
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: null,
          homePath: '/home/user',
        ),
        '/home/user/Downloads',
      );
    });

    test('falls back to HOME when XDG points at HOME', () {
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: '/home/user',
          homePath: '/home/user',
        ),
        '/home/user/Downloads',
      );
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: '/home/user/',
          homePath: '/home/user',
        ),
        '/home/user/Downloads',
      );
    });

    test('falls back to HOME for empty or relative XDG paths', () {
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: '',
          homePath: '/home/user',
        ),
        '/home/user/Downloads',
      );
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: 'Downloads',
          homePath: '/home/user',
        ),
        '/home/user/Downloads',
      );
    });

    test('returns null when neither XDG nor HOME is usable', () {
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: null,
          homePath: null,
        ),
        isNull,
      );
      expect(
        storage.selectLinuxIncomingDownloadsPath(
          xdgDownloadsPath: null,
          homePath: 'relative/home',
        ),
        isNull,
      );
    });
  });

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
