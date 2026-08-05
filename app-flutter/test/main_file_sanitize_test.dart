import 'dart:io';

import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/file_transfer/file_storage.dart' as storage;
import 'package:crypto/crypto.dart';
import 'package:app_flutter/src/platform/android_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop clipboard manager uses a ChangeNotifier provider', () async {
    final mainSource = await File('lib/main.dart').readAsString();

    expect(
      mainSource,
      contains('ChangeNotifierProvider<DesktopClipboardManager?>.value'),
    );
    expect(
      mainSource.split('\n').any(
            (line) => line
                .trim()
                .startsWith('Provider<DesktopClipboardManager?>.value'),
          ),
      isFalse,
    );
  });

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

  group('verified incoming file publication', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('rift-publish-test-');
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('copies verified staging content into the destination', () async {
      final bytes = List<int>.generate(1024, (index) => index % 251);
      final staging = File('${directory.path}/content.part');
      final destination = File('${directory.path}/Downloads/report.bin');
      await staging.writeAsBytes(bytes);

      final published = await storage.publishVerifiedIncomingFile(
        transferId: 'transfer-1',
        stagingPath: staging.path,
        destinationPath: destination.path,
        expectedByteSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
      );

      expect(published, destination.path);
      expect(await destination.readAsBytes(), bytes);
      expect(
        File('${destination.path}.rift-transfer-1.part').existsSync(),
        isFalse,
      );
    });

    test('accepts an already-published matching destination', () async {
      final bytes = <int>[1, 2, 3, 4];
      final staging = File('${directory.path}/content.part');
      final destination = File('${directory.path}/report.bin');
      await staging.writeAsBytes(bytes);
      await destination.writeAsBytes(bytes);

      final published = await storage.publishVerifiedIncomingFile(
        transferId: 'transfer-2',
        stagingPath: staging.path,
        destinationPath: destination.path,
        expectedByteSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
      );

      expect(published, destination.path);
    });

    test('removes the temporary file when verification fails', () async {
      final staging = File('${directory.path}/content.part');
      final destination = File('${directory.path}/report.bin');
      await staging.writeAsBytes(<int>[1, 2, 3, 4]);

      await expectLater(
        storage.publishVerifiedIncomingFile(
          transferId: 'transfer-3',
          stagingPath: staging.path,
          destinationPath: destination.path,
          expectedByteSize: 4,
          expectedSha256: sha256.convert(<int>[9, 9, 9, 9]).toString(),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(destination.existsSync(), isFalse);
      expect(
        File('${destination.path}.rift-transfer-3.part').existsSync(),
        isFalse,
      );
    });
  });

  group('incoming file destination', () {
    test('uses the saved default download path', () async {
      final directory =
          await Directory.systemTemp.createTemp('rift-downloads-');
      addTearDown(() => directory.delete(recursive: true));
      SharedPreferences.setMockInitialValues({
        AppPrefs.defaultDownloadPath: directory.path,
      });

      final path = await storage.buildIncomingFilePath('report.txt');

      expect(path,
          File(directory.path + Platform.pathSeparator + 'report.txt').path);
      expect(File(path!).parent.path, directory.path);
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
