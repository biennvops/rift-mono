import 'dart:convert';
import 'dart:io';

import 'package:daemon_dart/src/daemon.dart';
import 'package:test/test.dart';

const _iconA = <String, dynamic>{
  'mediaType': 'image/png',
  'dataBase64':
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  'byteSize': 70,
  'sha256': '4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5',
};

const _iconB = <String, dynamic>{
  'mediaType': 'image/png',
  'dataBase64':
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg==',
  'byteSize': 70,
  'sha256': '6a34118ba2e0bf5da5ab14cb63b121e2e8b2987a876668a9b2f9c30e1357470b',
};

void main() {
  late List<Map<String, dynamic>> csharpRecords;

  setUpAll(() async {
    final dartPostedIcon = normalizeNotificationIcon(_iconA);
    final dartUpdatedIcon = normalizeNotificationIcon(_iconB);
    expect(dartPostedIcon, isNotNull);
    expect(dartUpdatedIcon, isNotNull);
    final records = <Map<String, dynamic>>[
      _notificationRecord('posted', dartPostedIcon!),
      _notificationRecord('updated', dartUpdatedIcon!),
    ];
    csharpRecords = await _normalizeWithCSharp(records);
  });

  test('Dart wire icons are parsed by the C# implementation', () {
    expect(csharpRecords[0]['icon'], _iconA);
    expect(csharpRecords[1]['icon'], _iconB);
  });

  test(
    'C#-parsed notification update replaces the Dart daemon record',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'rift_notification_interop',
      );
      final daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
      );

      try {
        await daemon.start();
        for (final record in csharpRecords) {
          await daemon.handleJsonRpcRequest({
            'method': 'rift.notifyLocalNotificationEvent',
            'params': record,
          });
        }

        final listed = await daemon.handleJsonRpcRequest({
          'method': 'rift.listNotifications',
        });
        final notifications = (listed['notifications'] as List).cast<Map>();

        expect(notifications, hasLength(1));
        expect(notifications.single['notificationId'], 'notification-1');
        expect(notifications.single['icon'], _iconB);
      } finally {
        await daemon.stop();
        await tempDir.delete(recursive: true);
      }
    },
  );
}

Map<String, dynamic> _notificationRecord(
  String eventType,
  Map<String, dynamic> icon,
) => <String, dynamic>{
  'eventType': eventType,
  'notificationId': 'notification-1',
  'sourceDeviceId': 'rift-csharp-peer',
  'sourcePlatform': 'windows',
  'packageName': 'org.example.chat',
  'appName': 'Example Chat',
  'postedAt': '2026-08-08T00:00:00Z',
  'isDismissible': true,
  'isOpenable': false,
  'icon': icon,
};

Future<List<Map<String, dynamic>>> _normalizeWithCSharp(
  List<Map<String, dynamic>> records,
) async {
  final repoRoot = _findRepoRoot();
  final inputDirectory = await Directory.systemTemp.createTemp(
    'rift_notification_csharp_input',
  );
  final inputFile = File('${inputDirectory.path}/records.json');
  await inputFile.writeAsString(jsonEncode(records));

  try {
    final result = await Process.run('dotnet', <String>[
      'run',
      '--project',
      '${repoRoot.path}/tests-interop/runners/dotnet/Rift.NotificationInteropRunner.csproj',
      '--configuration',
      'Release',
      '--',
      inputFile.path,
    ], workingDirectory: repoRoot.path);
    if (result.exitCode != 0) {
      fail('C# interop runner failed: ${result.stderr}\n${result.stdout}');
    }

    final outputLines = const LineSplitter()
        .convert(result.stdout as String)
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final decoded = jsonDecode(outputLines.last) as List;
    return decoded
        .map((record) => Map<String, dynamic>.from(record as Map))
        .toList(growable: false);
  } finally {
    await inputDirectory.delete(recursive: true);
  }
}

Directory _findRepoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (Directory('${directory.path}/daemon-cs').existsSync() &&
        Directory('${directory.path}/tests-interop').existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Could not locate the Rift repository root');
}
