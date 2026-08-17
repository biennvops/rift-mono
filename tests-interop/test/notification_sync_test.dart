import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
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

  for (final mode in <String>['direct', 'ipc']) {
    test('Dart requester completes through C# $mode source executor', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'rift_notification_action_interop',
      );
      final transport = _RecordingTransport();
      final daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
        peerTransport: transport,
        mediaPlaybackActionTimeout: const Duration(seconds: 10),
      );

      try {
        await daemon.start();
        const csharpDeviceId = 'rift-csharp-source';
        await daemon.trustStoreForTesting.upsertPeer(
          PeerRecord(
            deviceId: csharpDeviceId,
            certDer: Uint8List(32),
            state: TrustState.trusted,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        final context =
            SessionContext(peerDeviceId: csharpDeviceId, isInitiator: false)
              ..handshakeState = HandshakeState.established
              ..trustState = TrustState.trusted
              ..capabilityNegotiated = true
              ..negotiatedCapabilities = [
                Capability(name: 'notification.sync', version: 1),
              ];
        daemon.sessionManagerForTesting.injectContextForTesting(context);
        await daemon.handleNotificationSyncProtocolMessageForTesting(
          csharpDeviceId,
          {
            'type': 'notification.posted',
            'payload': {
              'notificationId': 'csharp-local-notification',
              'sourceDeviceId': csharpDeviceId,
              'sourcePlatform': 'interop',
              'packageName': 'org.example.interop',
              'appName': 'Interop Source',
              'postedAt': '2026-08-10T00:00:00Z',
              'isDismissible': true,
              'isOpenable': false,
            },
          },
        );

        final action = await daemon.handleJsonRpcRequest({
          'method': 'rift.performNotificationAction',
          'params': {
            'sourceDeviceId': csharpDeviceId,
            'notificationId': 'csharp-local-notification',
            'action': 'dismiss',
          },
        });
        final requestEnvelope = transport.sentMessages.singleWhere(
          (message) => message['type'] == 'notification.actionRequest',
        );
        final csharpResult = await _executeCSharpAction(
          mode,
          localDeviceId: csharpDeviceId,
          requestEnvelope: requestEnvelope,
        );

        expect(csharpResult['mode'], mode);
        expect(csharpResult['directExecutionCount'], mode == 'direct' ? 1 : 0);
        if (mode == 'ipc') {
          expect(csharpResult['requestId'], isNotEmpty);
          expect(csharpResult['requestId'], isNot(action['operationId']));
        } else {
          expect(csharpResult['requestId'], isNull);
        }
        final resultEnvelope = Map<String, dynamic>.from(
          csharpResult['actionResultEnvelope'] as Map,
        );
        final resultPayload = Map<String, dynamic>.from(
          resultEnvelope['payload'] as Map,
        );
        expect(resultPayload['operationId'], action['operationId']);
        expect(resultPayload['success'], isTrue);

        await daemon.handleNotificationSyncProtocolMessageForTesting(
          csharpDeviceId,
          resultEnvelope,
        );
        final operation = await daemon.handleJsonRpcRequest({
          'method': 'rift.getOperation',
          'params': {'operationId': action['operationId']},
        });
        expect(operation['state'], 'Done');
      } finally {
        await daemon.stop();
        await tempDir.delete(recursive: true);
      }
    });
  }
}

class _RecordingTransport implements Transport {
  final StreamController<TransportMessage> _messages =
      StreamController<TransportMessage>.broadcast();
  final StreamController<String> _disconnects =
      StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sentMessages = <Map<String, dynamic>>[];

  @override
  Stream<TransportMessage> get onMessageReceived => _messages.stream;

  @override
  Stream<String> get onPeerDisconnected => _disconnects.stream;

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async => expectedDeviceId ?? 'rift-csharp-source';

  @override
  void disconnect(String peerDeviceId) => _disconnects.add(peerDeviceId);

  @override
  Uint8List? getPeerCert(String peerDeviceId) => Uint8List(32);

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) =>
      const PeerSocketEndpoint(address: '127.0.0.1', port: 1);

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    sentMessages.add(jsonDecode(utf8.decode(message)) as Map<String, dynamic>);
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {}

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {
    await _messages.close();
    await _disconnects.close();
  }
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

Future<Map<String, dynamic>> _executeCSharpAction(
  String mode, {
  required String localDeviceId,
  required Map<String, dynamic> requestEnvelope,
}) async {
  final repoRoot = _findRepoRoot();
  final process = await Process.start('dotnet', <String>[
    'run',
    '--project',
    '${repoRoot.path}/tests-interop/runners/dotnet/Rift.NotificationInteropRunner.csproj',
    '--configuration',
    'Release',
    '--',
    'action',
    mode,
  ], workingDirectory: repoRoot.path);
  process.stdin.write(
    jsonEncode({
      'localDeviceId': localDeviceId,
      'requestEnvelope': requestEnvelope,
    }),
  );
  await process.stdin.close();
  final stdout = await process.stdout.transform(utf8.decoder).join();
  final stderr = await process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    fail('C# action runner failed: $stderr\n$stdout');
  }
  final outputLines = const LineSplitter()
      .convert(stdout)
      .where((line) => line.trim().isNotEmpty)
      .toList();
  return Map<String, dynamic>.from(jsonDecode(outputLines.last) as Map);
}

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
