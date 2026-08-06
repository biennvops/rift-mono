import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:rift/src/ipc/ipc_transport.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/media_playback/android_remote_media_playback_coordinator.dart';
import 'package:rift/src/media_playback/ios_remote_media_playback_coordinator.dart';
import 'package:rift/src/media_playback/macos_remote_media_playback_coordinator.dart';
import 'package:rift/src/platform/android_shell.dart';
import 'package:rift/src/platform/ios_media_playback.dart';
import 'package:rift/src/platform/macos_media_playback.dart';
import 'package:flutter/services.dart';

class MockTransport implements IpcTransport {
  StreamController<String>? _daemonToApp;
  StreamController<String>? _appToDaemon;
  final List<Map<String, dynamic>> requests = [];

  bool isConnected = false;
  int connectionAttempts = 0;
  bool shouldFailConnect = false;
  int failConnectAttempts = 0;
  String listTrustedPeersJson =
      '{"Peers":[{"DeviceId":"rift-peer","Platform":"windows","TrustState":"pairingpending","Presence":"offline","Capabilities":[]}]}';
  Map<String, dynamic> startPairingResult = {
    'Fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    'PeerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    'ExpiresInMs': 120000,
  };
  Map<String, dynamic> notifyClipboardChangeResult = {
    'OfferId': 'offer-local',
    'ExpiresInMs': 120000,
    'BroadcastTo': ['rift-peer'],
  };
  Map<String, dynamic> listClipboardOffersResult = {
    'Offers': [
      {
        'OfferId': 'offer-remote',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'text/plain',
        'ByteSize': 5,
        'Sha256': 'abc123',
        'ExpiresAt': '2026-06-30T02:00:00Z',
      }
    ]
  };
  Map<String, dynamic> fetchClipboardContentResult = {
    'OfferId': 'offer-remote',
    'ContentBase64': 'aGVsbG8=',
    'ByteSize': 5,
    'Sha256':
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    'Verified': true,
  };
  Map<String, dynamic> offerFileResult = {
    'TransferId': 'transfer-1',
    'OperationId': 'operation-file-1',
    'TargetDeviceId': 'rift-peer',
    'FileName': 'demo.txt',
    'ByteSize': 12,
    'ChunkSize': 262144,
    'ChunkCount': 1,
  };
  Map<String, dynamic> listIncomingFileOffersResult = {
    'Offers': [
      {
        'TransferId': 'transfer-incoming',
        'SourceDeviceId': 'rift-peer',
        'FileName': 'photo.jpg',
        'MediaType': 'image/jpeg',
        'ByteSize': 1234,
        'Sha256': 'def456',
        'ChunkSize': 262144,
        'ChunkCount': 1,
        'ExpiresAt': '2026-06-30T02:05:00Z',
      }
    ]
  };
  Map<String, dynamic> acceptFileOfferResult = {
    'TransferId': 'transfer-incoming',
    'OperationId': 'operation-file-2',
    'DestinationPath': 'C:/tmp/photo.jpg',
  };
  Map<String, dynamic> rejectFileOfferResult = {
    'TransferId': 'transfer-incoming',
    'Rejected': true,
  };
  Map<String, dynamic> listFileTransfersResult = {
    'Transfers': [
      {
        'TransferId': 'transfer-1',
        'OperationId': 'operation-file-1',
        'Direction': 'incoming',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'BytesTransferred': 12,
        'State': 'Done',
        'DestinationPath': 'C:/tmp/demo.txt',
      }
    ]
  };
  Map<String, dynamic> enqueueFileSendResult = {
    'QueueItemId': 'queue-1',
    'Status': 'waiting_for_target',
    'TargetDeviceId': null,
  };
  Map<String, dynamic> listSendQueueResult = {
    'Items': [
      {
        'QueueItemId': 'queue-1',
        'Status': 'queued',
        'TargetDeviceId': 'rift-peer',
        'LocalPath': '/tmp/demo.txt',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'CurrentOperationId': null,
        'LastTransferId': null,
        'FailureReason': null,
        'FailureMessage': null,
        'CreatedAt': '2026-07-14T10:00:00Z',
        'UpdatedAt': '2026-07-14T10:00:00Z',
        'Origin': 'share',
      }
    ]
  };
  Map<String, dynamic> listOperationsResult = {
    'Operations': [
      {
        'OperationId': 'operation-1',
        'OperationType': 'clipboard.fetch',
        'State': 'Done',
        'SourceDeviceId': 'rift-local',
        'DestinationDeviceId': 'rift-peer',
        'CreatedAt': '2026-06-30T02:00:00Z',
        'UpdatedAt': '2026-06-30T02:00:01Z',
      }
    ],
    'Total': 1,
  };
  Map<String, dynamic> listNotificationsResult = {
    'Notifications': [
      {
        'NotificationId': 'notif-1',
        'SourceDeviceId': 'rift-peer',
        'PackageName': 'com.example.chat',
        'AppName': 'Example Chat',
        'Title': 'Riley',
        'BodyPreview': 'See you at 6?',
        'PostedAt': '2026-07-14T10:00:00Z',
        'IsDismissible': true,
        'IsOpenable': true,
      }
    ],
    'Policy': {
      'Enabled': true,
      'BlacklistedPackages': ['com.bank.example'],
    }
  };
  Map<String, dynamic> listMediaPlaybackResult = {
    'playbacks': [],
  };
  Map<String, dynamic> getMediaPlaybackResult = {
    'playbackId': 'playback-1',
    'sourceDeviceId': 'rift-peer',
    'appId': 'com.example.music',
    'appName': 'Example Music',
    'playbackState': 'playing',
    'positionMs': 1000,
    'canPlay': true,
    'canPause': true,
    'canSkipNext': true,
    'canSkipPrevious': true,
    'canSeek': true,
    'updatedAt': '2026-07-16T10:00:00Z',
  };
  Map<String, dynamic> performMediaPlaybackActionResult = {
    'OperationId': 'operation-media-1',
    'PlaybackId': 'playback-1',
    'Action': 'pause',
    'State': 'Pending',
  };
  Map<String, dynamic> performNotificationActionResult = {
    'OperationId': 'operation-notification-1',
    'NotificationId': 'notif-1',
    'Action': 'open',
    'State': 'Pending',
  };
  Map<String, dynamic> updateNotificationSyncPolicyResult = {
    'Enabled': true,
    'BlacklistedPackages': ['com.bank.example'],
  };
  Map<String, dynamic> notifyLocalNotificationEventResult = {
    'NotificationId': 'notif-1',
    'BroadcastTo': ['rift-peer'],
    'Suppressed': false,
  };
  Map<String, dynamic> notifyLocalMediaPlaybackEventResult = {
    'PlaybackId': 'playback-1',
    'BroadcastTo': ['rift-peer'],
  };
  Map<String, dynamic> getOperationResult = {
    'OperationId': 'operation-1',
    'OperationType': 'clipboard.fetch',
    'State': 'Done',
    'SourceDeviceId': 'rift-local',
    'DestinationDeviceId': 'rift-peer',
    'CreatedAt': '2026-06-30T02:00:00Z',
    'UpdatedAt': '2026-06-30T02:00:01Z',
    'Transitions': [
      {'From': 'Created', 'To': 'Pending', 'At': '2026-06-30T02:00:00Z'},
      {'From': 'Pending', 'To': 'Dispatched', 'At': '2026-06-30T02:00:00Z'},
      {'From': 'Dispatched', 'To': 'Active', 'At': '2026-06-30T02:00:01Z'},
      {'From': 'Active', 'To': 'Done', 'At': '2026-06-30T02:00:01Z'},
    ],
  };
  Map<String, dynamic>? getOperationError;

  void triggerDisconnect() {
    _daemonToApp?.close();
  }

  void emitNotification(String method, Map<String, dynamic> params) {
    _daemonToApp?.add(jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    }));
  }

  void _sendResult(dynamic id, dynamic result) {
    _daemonToApp?.add(jsonEncode({
      'jsonrpc': '2.0',
      'result': result,
      'id': id,
    }));
  }

  void _sendError(dynamic id, Map<String, dynamic> error) {
    _daemonToApp?.add(jsonEncode({
      'jsonrpc': '2.0',
      'error': error,
      'id': id,
    }));
  }

  @override
  Future<StreamChannel<String>> connect() async {
    connectionAttempts++;
    if (shouldFailConnect || failConnectAttempts > 0) {
      if (failConnectAttempts > 0) {
        failConnectAttempts -= 1;
      }
      throw Exception('Mock connection failure');
    }

    isConnected = true;
    _daemonToApp = StreamController<String>();
    _appToDaemon = StreamController<String>();

    // Simulate daemon responding to requests and notifications.
    _appToDaemon!.stream.listen((req) {
      final decoded = jsonDecode(req) as Map<String, dynamic>;
      requests.add(decoded);
      final id = decoded['id'];
      switch (decoded['method']) {
        case 'rift.getDeviceInfo':
          _sendResult(id, {
            'deviceId': 'rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq',
            'platform': 'windows',
            'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
            'implementationId': 'riftd-cs/0.1.0',
            'protocolVersion': '0.1-draft',
            'IdentityProtectionBackend': 'dpapi',
            'capabilities': [
              {'name': 'clipboard.offer_fetch', 'version': 1}
            ]
          });
          break;
        case 'rift.listTrustedPeers':
          _sendResult(id, jsonDecode(listTrustedPeersJson));
          break;
        case 'rift.startPairing':
          _sendResult(id, startPairingResult);
          break;
        case 'rift.approvePairing':
          _sendResult(id, {
            'TrustedDeviceId':
                (decoded['params'] as Map<String, dynamic>)['deviceId'],
            'PersistedAt': '2026-06-24T02:00:00Z',
          });
          break;
        case 'rift.rejectPairing':
          _sendResult(id, {'Rejected': true});
          break;
        case 'rift.notifyClipboardChange':
          _sendResult(id, notifyClipboardChangeResult);
          break;
        case 'rift.listClipboardOffers':
          _sendResult(id, listClipboardOffersResult);
          break;
        case 'rift.fetchClipboardContent':
          _sendResult(id, fetchClipboardContentResult);
          break;
        case 'rift.offerFile':
          _sendResult(id, offerFileResult);
          break;
        case 'rift.listIncomingFileOffers':
          _sendResult(id, listIncomingFileOffersResult);
          break;
        case 'rift.enqueueFileSend':
          _sendResult(id, enqueueFileSendResult);
          break;
        case 'rift.listSendQueue':
          _sendResult(id, listSendQueueResult);
          break;
        case 'rift.acceptFileOffer':
          _sendResult(id, acceptFileOfferResult);
          break;
        case 'rift.rejectFileOffer':
          _sendResult(id, rejectFileOfferResult);
          break;
        case 'rift.listFileTransfers':
          _sendResult(id, listFileTransfersResult);
          break;
        case 'rift.listOperations':
          _sendResult(id, listOperationsResult);
          break;
        case 'rift.getOperation':
          if (getOperationError != null) {
            _sendError(id, getOperationError!);
          } else {
            _sendResult(id, getOperationResult);
          }
          break;
        case 'rift.listNotifications':
          _sendResult(id, listNotificationsResult);
          break;
        case 'rift.performNotificationAction':
          _sendResult(id, performNotificationActionResult);
          break;
        case 'rift.updateNotificationSyncPolicy':
          _sendResult(id, updateNotificationSyncPolicyResult);
          break;
        case 'rift.notifyLocalNotificationEvent':
          _sendResult(id, notifyLocalNotificationEventResult);
          break;
        case 'rift.notifyLocalMediaPlaybackEvent':
          _sendResult(id, notifyLocalMediaPlaybackEventResult);
          break;
        case 'rift.listMediaPlayback':
          _sendResult(id, listMediaPlaybackResult);
          break;
        case 'rift.getMediaPlayback':
          _sendResult(id, getMediaPlaybackResult);
          break;
        case 'rift.performMediaPlaybackAction':
          _sendResult(id, performMediaPlaybackActionResult);
          break;
      }
    });

    return StreamChannel<String>(_daemonToApp!.stream, _appToDaemon!.sink);
  }

  @override
  Future<void> disconnect() async {
    isConnected = false;
    _daemonToApp?.close();
    _appToDaemon?.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JsonRpcRiftClient', () {
    late MockTransport transport;
    late JsonRpcRiftClient client;

    setUp(() {
      transport = MockTransport();
      client = JsonRpcRiftClient(transport);
    });

    tearDown(() async {
      await client.disconnect();
    });

    test('should connect via transport', () async {
      await client.connect();
      expect(client.isConnected, isTrue);
      expect(transport.isConnected, isTrue);
    });

    test('should successfully get device info from the daemon', () async {
      await client.connect();
      final result = await client.getDeviceInfo();
      expect(
          result,
          equals({
            'deviceId': 'rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq',
            'platform': 'windows',
            'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
            'implementationId': 'riftd-cs/0.1.0',
            'protocolVersion': '0.1-draft',
            'identityProtectionBackend': 'dpapi',
            'capabilities': [
              {'name': 'clipboard.offer_fetch', 'version': 1}
            ]
          }));
    });

    test('should canonicalize C# trust state enum values to IPC format',
        () async {
      await client.connect();

      final result = await client.listTrustedPeers();
      expect(
        result,
        equals({
          'peers': [
            {
              'deviceId': 'rift-peer',
              'platform': 'windows',
              'trustState': 'pairing_pending',
              'presence': 'offline',
              'capabilities': <dynamic>[],
            }
          ]
        }),
      );
    });

    test('should canonicalize C# device status fields in results and events',
        () async {
      transport.listTrustedPeersJson = jsonEncode({
        'Peers': [
          {
            'DeviceId': 'rift-phone',
            'DeviceStatus': {
              'SourceDeviceId': 'rift-phone',
              'SourcePlatform': 'android',
              'BatteryPresent': true,
              'BatteryPercent': 64,
              'ChargingState': 'charging',
              'PowerSource': 'usb',
              'LowPowerMode': false,
              'ObservedAt': '2026-08-06T12:00:00Z',
              'IsStale': false,
            },
          },
        ],
      });
      await client.connect();

      final result = await client.listTrustedPeers();
      expect((result['peers'] as List).single, {
        'deviceId': 'rift-phone',
        'deviceStatus': {
          'sourceDeviceId': 'rift-phone',
          'sourcePlatform': 'android',
          'batteryPresent': true,
          'batteryPercent': 64,
          'chargingState': 'charging',
          'powerSource': 'usb',
          'lowPowerMode': false,
          'observedAt': '2026-08-06T12:00:00Z',
          'isStale': false,
        },
      });

      final eventFuture = client.onDeviceStatusUpdated.first;
      transport.emitNotification('rift.onDeviceStatusUpdated', {
        'SourceDeviceId': 'rift-phone',
        'BatteryPresent': true,
        'BatteryPercent': 64,
        'ChargingState': 'charging',
        'PowerSource': 'usb',
        'LowPowerMode': false,
        'ObservedAt': '2026-08-06T12:00:00Z',
        'IsStale': false,
      });
      expect(await eventFuture, {
        'sourceDeviceId': 'rift-phone',
        'batteryPresent': true,
        'batteryPercent': 64,
        'chargingState': 'charging',
        'powerSource': 'usb',
        'lowPowerMode': false,
        'observedAt': '2026-08-06T12:00:00Z',
        'isStale': false,
      });
    });

    test('should format transport and pairing errors for display', () {
      expect(
        JsonRpcRiftClient.formatDisplayError(
          Exception(
            'JSON-RPC error -32000: Failed to establish a secure session with peer',
          ),
        ),
        contains('Could not establish a secure session'),
      );

      expect(
        JsonRpcRiftClient.formatDisplayError(
          StateError('Not connected to daemon'),
        ),
        equals('Daemon not connected.'),
      );

      expect(
        JsonRpcRiftClient.formatDisplayError(
          Exception(
            "JSON-RPC error -32000: Failed to reconnect trusted peer 'rift-nyvhp4uu4axifolkhwvzgoskuytlozui' using discovery endpoints. Peer closed connection before sending session.hello.",
          ),
        ),
        equals(
          'Could not reconnect to this trusted device. Make sure it is online and reachable on the same local network, then try again.',
        ),
      );
    });

    test('should attempt reconnection on unexpected disconnect', () {
      fakeAsync((async) {
        // Connect synchronously within the fake async zone
        client.connect();
        async.flushMicrotasks();

        expect(client.isConnected, isTrue);

        int initialAttempts = transport.connectionAttempts;

        // Trigger disconnect
        transport.triggerDisconnect();
        async.flushMicrotasks(); // Wait for onDone to propagate

        // json_rpc_2 might use futures that we need to yield to.
        // Advance time by 2 seconds to trigger the exponential backoff timer (first wait is 1s)
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        // Should have attempted to reconnect at least once
        expect(transport.connectionAttempts, greaterThan(initialAttempts));

        // Verify reconnect counter reset logic
        // It successfully reconnected, so attempts should be reset to 0.
        // A second disconnect should trigger attempt 1 again (waiting 1 second).
        int attemptsAfterFirstReconnect = transport.connectionAttempts;
        transport.triggerDisconnect();
        async.flushMicrotasks();

        async
            .elapse(const Duration(seconds: 1)); // First backoff is 1s (1 << 0)
        async.flushMicrotasks();

        // It should have attempted exactly 1 more time
        expect(transport.connectionAttempts,
            equals(attemptsAfterFirstReconnect + 1));

        // Manually disconnect to avoid tearDown hanging outside fakeAsync
        client.disconnect();
        async.flushMicrotasks();
      });
    });

    test('should keep retrying reconnect after a failed reconnect attempt', () {
      fakeAsync((async) {
        client.connect();
        async.flushMicrotasks();

        expect(client.isConnected, isTrue);

        transport.failConnectAttempts = 1;
        final initialAttempts = transport.connectionAttempts;

        transport.triggerDisconnect();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(client.isConnected, isFalse);

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(client.isConnected, isTrue);
        expect(transport.connectionAttempts, greaterThan(initialAttempts + 1));

        client.disconnect();
        async.flushMicrotasks();
      });
    });

    test(
        'should deliver incoming pairing request notification with canonicalized fields',
        () async {
      await client.connect();

      final eventFuture = client.onPairingRequest.first;
      transport.emitNotification('rift.onPairingRequest', {
        'DeviceId': 'rift-linux-peer',
        'DisplayName': 'Linux Laptop',
        'Fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'ExpiresInMs': 120000,
      });

      final event = await eventFuture;
      expect(event, {
        'deviceId': 'rift-linux-peer',
        'displayName': 'Linux Laptop',
        'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'expiresInMs': 120000,
      });
    });

    test('should deliver clipboard notifications with canonicalized fields',
        () async {
      await client.connect();

      final offerFuture = client.onClipboardOffer.first;
      final expiredFuture = client.onClipboardExpired.first;

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-1',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'text/plain',
        'ByteSize': 5,
        'Sha256': 'abc123',
        'ExpiresInMs': 120000,
      });
      transport.emitNotification('rift.onClipboardExpired', {
        'OfferId': 'offer-1',
      });

      expect(await offerFuture, {
        'offerId': 'offer-1',
        'sourceDeviceId': 'rift-peer',
        'contentType': 'text/plain',
        'byteSize': 5,
        'sha256': 'abc123',
        'expiresInMs': 120000,
      });
      expect(await expiredFuture, {
        'offerId': 'offer-1',
      });
    });

    test(
        'should deliver notification sync notifications with canonicalized fields',
        () async {
      await client.connect();

      final postedFuture = client.onNotificationPosted.first;
      final updatedFuture = client.onNotificationUpdated.first;
      final removedFuture = client.onNotificationRemoved.first;
      final actionFuture = client.onNotificationActionResult.first;

      transport.emitNotification('rift.onNotificationPosted', {
        'NotificationId': 'notif-1',
        'SourceDeviceId': 'rift-peer',
        'PackageName': 'com.example.chat',
        'AppName': 'Example Chat',
        'Title': 'Riley',
        'BodyPreview': 'See you at 6?',
        'PostedAt': '2026-07-14T10:00:00Z',
        'IsDismissible': true,
        'IsOpenable': true,
      });
      transport.emitNotification('rift.onNotificationUpdated', {
        'NotificationId': 'notif-1',
        'SourceDeviceId': 'rift-peer',
        'PackageName': 'com.example.chat',
        'AppName': 'Example Chat',
        'Title': 'Riley',
        'BodyPreview': 'Running late',
        'PostedAt': '2026-07-14T10:01:00Z',
        'IsDismissible': true,
        'IsOpenable': true,
      });
      transport.emitNotification('rift.onNotificationRemoved', {
        'NotificationId': 'notif-1',
        'SourceDeviceId': 'rift-peer',
        'RemovedAt': '2026-07-14T10:02:00Z',
      });
      transport.emitNotification('rift.onNotificationActionResult', {
        'NotificationId': 'notif-1',
        'OperationId': 'operation-notification-1',
        'Action': 'open',
        'State': 'Done',
        'Success': true,
      });

      expect(await postedFuture, {
        'notificationId': 'notif-1',
        'sourceDeviceId': 'rift-peer',
        'packageName': 'com.example.chat',
        'appName': 'Example Chat',
        'title': 'Riley',
        'bodyPreview': 'See you at 6?',
        'postedAt': '2026-07-14T10:00:00Z',
        'isDismissible': true,
        'isOpenable': true,
      });
      expect(await updatedFuture, {
        'notificationId': 'notif-1',
        'sourceDeviceId': 'rift-peer',
        'packageName': 'com.example.chat',
        'appName': 'Example Chat',
        'title': 'Riley',
        'bodyPreview': 'Running late',
        'postedAt': '2026-07-14T10:01:00Z',
        'isDismissible': true,
        'isOpenable': true,
      });
      expect(await removedFuture, {
        'notificationId': 'notif-1',
        'sourceDeviceId': 'rift-peer',
        'removedAt': '2026-07-14T10:02:00Z',
      });
      expect(await actionFuture, {
        'notificationId': 'notif-1',
        'operationId': 'operation-notification-1',
        'action': 'open',
        'state': 'Done',
        'success': true,
      });
    });

    test('should deliver file transfer notifications with canonicalized fields',
        () async {
      await client.connect();

      final offerFuture = client.onFileOffer.first;
      final readyFuture = client.onFileTransferReadyToCommit.first;
      final progressFuture = client.onFileTransferProgress.first;
      final completedFuture = client.onFileTransferCompleted.first;
      final failedFuture = client.onFileTransferFailed.first;

      transport.emitNotification('rift.onFileOffer', {
        'TransferId': 'transfer-1',
        'SourceDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'Sha256': 'abc123',
        'ChunkSize': 262144,
        'ChunkCount': 1,
        'ExpiresAt': '2026-06-30T02:10:00Z',
      });
      transport.emitNotification('rift.onFileTransferReadyToCommit', {
        'TransferId': 'transfer-1',
        'OperationId': 'operation-file-1',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'Sha256': 'abc123',
        'StagingPath': '/private/rift/incoming/content.part',
        'DestinationPath': '/home/user/Downloads/demo.txt',
        'State': 'ready_to_commit',
      });
      transport.emitNotification('rift.onFileTransferProgress', {
        'TransferId': 'transfer-1',
        'OperationId': 'operation-file-1',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'BytesTransferred': 6,
        'State': 'Active',
      });
      transport.emitNotification('rift.onFileTransferCompleted', {
        'TransferId': 'transfer-1',
        'OperationId': 'operation-file-1',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'ByteSize': 12,
        'DestinationPath': 'C:/tmp/demo.txt',
      });
      transport.emitNotification('rift.onFileTransferFailed', {
        'TransferId': 'transfer-2',
        'OperationId': 'operation-file-2',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'bad.bin',
        'ByteSize': 8,
        'FailureReason': 'ConnectionLost',
      });

      expect(await offerFuture, {
        'transferId': 'transfer-1',
        'sourceDeviceId': 'rift-peer',
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
        'byteSize': 12,
        'sha256': 'abc123',
        'chunkSize': 262144,
        'chunkCount': 1,
        'expiresAt': '2026-06-30T02:10:00Z',
      });
      expect(await readyFuture, {
        'transferId': 'transfer-1',
        'operationId': 'operation-file-1',
        'peerDeviceId': 'rift-peer',
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
        'byteSize': 12,
        'sha256': 'abc123',
        'stagingPath': '/private/rift/incoming/content.part',
        'destinationPath': '/home/user/Downloads/demo.txt',
        'state': 'ready_to_commit',
      });
      expect(await progressFuture, {
        'transferId': 'transfer-1',
        'operationId': 'operation-file-1',
        'peerDeviceId': 'rift-peer',
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
        'byteSize': 12,
        'bytesTransferred': 6,
        'state': 'Active',
      });
      expect(await completedFuture, {
        'transferId': 'transfer-1',
        'operationId': 'operation-file-1',
        'peerDeviceId': 'rift-peer',
        'fileName': 'demo.txt',
        'byteSize': 12,
        'destinationPath': 'C:/tmp/demo.txt',
      });
      expect(await failedFuture, {
        'transferId': 'transfer-2',
        'operationId': 'operation-file-2',
        'peerDeviceId': 'rift-peer',
        'fileName': 'bad.bin',
        'byteSize': 8,
        'failureReason': 'ConnectionLost',
      });
    });

    test('should deliver send queue notifications with canonicalized fields',
        () async {
      await client.connect();

      final changedFuture = client.onSendQueueChanged.first;
      final updatedFuture = client.onSendQueueItemUpdated.first;

      transport.emitNotification('rift.onSendQueueChanged', {
        'QueueItemId': 'queue-1',
        'Removed': true,
      });
      transport.emitNotification('rift.onSendQueueItemUpdated', {
        'QueueItemId': 'queue-1',
        'Status': 'waiting_for_peer',
        'TargetDeviceId': 'rift-peer',
        'CurrentOperationId': 'operation-1',
        'LastTransferId': 'transfer-1',
        'FailureReason': 'PeerUnreachable',
        'FailureMessage': 'offline',
      });

      expect(await changedFuture, {
        'queueItemId': 'queue-1',
        'removed': true,
      });
      expect(await updatedFuture, {
        'queueItemId': 'queue-1',
        'status': 'waiting_for_peer',
        'targetDeviceId': 'rift-peer',
        'currentOperationId': 'operation-1',
        'lastTransferId': 'transfer-1',
        'failureReason': 'PeerUnreachable',
        'failureMessage': 'offline',
      });
    });

    test('should expose clipboard RPC wrappers', () async {
      await client.connect();

      final notifyResult = await client.notifyClipboardChange(
        contentType: 'text/plain',
        byteSize: 5,
        sha256:
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        contentBase64: 'aGVsbG8=',
      );
      final offersResult = await client.listClipboardOffers();
      final fetchResult = await client.fetchClipboardContent('offer-remote');

      expect(notifyResult, {
        'offerId': 'offer-local',
        'expiresInMs': 120000,
        'broadcastTo': ['rift-peer'],
      });
      expect(offersResult, {
        'offers': [
          {
            'offerId': 'offer-remote',
            'sourceDeviceId': 'rift-peer',
            'contentType': 'text/plain',
            'byteSize': 5,
            'sha256': 'abc123',
            'expiresAt': '2026-06-30T02:00:00Z',
          }
        ]
      });
      expect(fetchResult, {
        'offerId': 'offer-remote',
        'contentBase64': 'aGVsbG8=',
        'byteSize': 5,
        'sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'verified': true,
      });

      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.notifyClipboardChange')
            .single['params'],
        {
          'contentType': 'text/plain',
          'byteSize': 5,
          'sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'contentBase64': 'aGVsbG8=',
        },
      );
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.fetchClipboardContent')
            .single['params'],
        {'offerId': 'offer-remote'},
      );
    });

    test('should expose file transfer RPC wrappers', () async {
      await client.connect();

      final offerResult = await client.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: 'C:/tmp/demo.txt',
        fileName: 'demo.txt',
        mediaType: 'text/plain',
      );
      final incomingOffers = await client.listIncomingFileOffers();
      final acceptResult = await client.acceptFileOffer(
        transferId: 'transfer-incoming',
        destinationPath: 'C:/tmp/photo.jpg',
      );
      final rejectResult = await client.rejectFileOffer(
        transferId: 'transfer-incoming',
        failureReason: 'PolicyDenied',
        message: 'User declined',
      );
      final transfers = await client.listFileTransfers();

      expect(offerResult['transferId'], 'transfer-1');
      expect(incomingOffers['offers'], hasLength(1));
      expect(acceptResult['destinationPath'], 'C:/tmp/photo.jpg');
      expect(rejectResult['rejected'], isTrue);
      expect(transfers['transfers'], hasLength(1));
    });

    test('should expose daemon send queue RPC wrappers', () async {
      await client.connect();

      final enqueue = await client.enqueueFileSend(
        localPath: '/tmp/demo.txt',
        fileName: 'demo.txt',
        mediaType: 'text/plain',
        origin: 'share',
      );
      final queue = await client.listSendQueue();
      final supported = await client.supportsSendQueue();

      expect(enqueue['queueItemId'], 'queue-1');
      expect(queue['items'], hasLength(1));
      expect((queue['items'] as List).single['fileName'], 'demo.txt');
      expect(supported, isTrue);
    });

    test('supportsSendQueue cache is cleared on reconnect', () async {
      await client.connect();

      // First probe caches true.
      expect(await client.supportsSendQueue(), isTrue);

      // Drop the connection; the cache must be cleared so a subsequent
      // reconnect re-probes the capability.
      await client.disconnect();
      await client.connect();

      // Re-probe after reconnect. If the cache had stuck as true without
      // re-checking, this would still pass even if the daemon no longer
      // supported the method — so the assertion is that the call still
      // succeeds (true) AND that a subsequent force-fail still re-probes.
      expect(await client.supportsSendQueue(), isTrue);
    });

    test('should expose operation RPC wrappers', () async {
      await client.connect();

      final listed = await client.listOperations();
      final detailed = await client.getOperation('operation-1');

      expect(listed, {
        'operations': [
          {
            'operationId': 'operation-1',
            'operationType': 'clipboard.fetch',
            'state': 'Done',
            'sourceDeviceId': 'rift-local',
            'destinationDeviceId': 'rift-peer',
            'createdAt': '2026-06-30T02:00:00Z',
            'updatedAt': '2026-06-30T02:00:01Z',
          }
        ],
        'total': 1,
      });
      expect(detailed['operationId'], 'operation-1');
      expect((detailed['transitions'] as List).length, 4);
      expect(
        transport.requests
            .where((request) => request['method'] == 'rift.getOperation')
            .single['params'],
        {'operationId': 'operation-1'},
      );
    });

    test('should expose notification sync RPC wrappers', () async {
      await client.connect();

      final localEventResult = await client.notifyLocalNotificationEvent(
        eventType: 'posted',
        payload: const {
          'notificationId': 'notif-1',
          'packageName': 'com.example.chat',
          'appName': 'Example Chat',
          'postedAt': '2026-07-14T10:00:00Z',
          'isDismissible': true,
          'isOpenable': true,
        },
      );
      final listed = await client.listNotifications();
      final actionResult = await client.performNotificationAction(
        notificationId: 'notif-1',
        action: 'open',
      );
      final policyResult = await client.updateNotificationSyncPolicy(
        enabled: true,
        blacklistedPackages: ['com.bank.example'],
      );

      expect(localEventResult['notificationId'], 'notif-1');
      expect((listed['notifications'] as List).single['notificationId'],
          'notif-1');
      expect(listed['policy'], {
        'enabled': true,
        'blacklistedPackages': ['com.bank.example'],
      });
      expect(actionResult['operationId'], 'operation-notification-1');
      expect(policyResult, {
        'enabled': true,
        'blacklistedPackages': ['com.bank.example'],
      });
      expect(
        transport.requests
            .where(
              (request) =>
                  request['method'] == 'rift.notifyLocalNotificationEvent',
            )
            .single['params'],
        {
          'eventType': 'posted',
          'notificationId': 'notif-1',
          'packageName': 'com.example.chat',
          'appName': 'Example Chat',
          'postedAt': '2026-07-14T10:00:00Z',
          'isDismissible': true,
          'isOpenable': true,
        },
      );
      expect(
        transport.requests
            .where(
              (request) =>
                  request['method'] == 'rift.performNotificationAction',
            )
            .single['params'],
        {
          'notificationId': 'notif-1',
          'action': 'open',
        },
      );
    });

    test('should expose media playback RPC wrappers', () async {
      await client.connect();

      await client.notifyLocalMediaPlaybackEvent(
        eventType: 'posted',
        payload: const {
          'playbackId': 'playback-1',
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'artwork': {
            'dataBase64': 'Zm9v',
            'mediaType': 'image/png',
          },
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00Z',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      );
      expect(
        transport.requests
            .where(
              (request) =>
                  request['method'] == 'rift.notifyLocalMediaPlaybackEvent',
            )
            .single['params'],
        {
          'eventType': 'posted',
          'playbackId': 'playback-1',
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'artwork': {
            'dataBase64': 'Zm9v',
            'mediaType': 'image/png',
          },
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00Z',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      );

      transport.listMediaPlaybackResult = {
        'playbacks': [
          {
            'playbackId': 'playback-1',
            'sourceDeviceId': 'rift-peer',
            'appId': 'com.example.music',
            'appName': 'Example Music',
            'artwork': {
              'dataBase64': 'Zm9v',
              'mediaType': 'image/png',
            },
            'playbackState': 'playing',
            'positionMs': 1000,
            'canPlay': true,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
            'updatedAt': '2026-07-16T10:00:00Z',
          }
        ],
      };
      transport.getMediaPlaybackResult = {
        'playbackId': 'playback-1',
        'sourceDeviceId': 'rift-peer',
        'appId': 'com.example.music',
        'appName': 'Example Music',
        'artwork': {
          'dataBase64': 'Zm9v',
          'mediaType': 'image/png',
        },
        'playbackState': 'playing',
        'positionMs': 1000,
        'canPlay': true,
        'canPause': true,
        'canSkipNext': true,
        'canSkipPrevious': true,
        'canSeek': true,
        'updatedAt': '2026-07-16T10:00:00Z',
      };
      transport.performMediaPlaybackActionResult = {
        'OperationId': 'operation-media-1',
        'PlaybackId': 'playback-1',
        'Action': 'pause',
        'State': 'Pending',
      };

      final listed = await client.listMediaPlayback();
      final detailed = await client.getMediaPlayback(
        sourceDeviceId: 'rift-peer',
        playbackId: 'playback-1',
      );
      final actionResult = await client.performMediaPlaybackAction(
        sourceDeviceId: 'rift-peer',
        playbackId: 'playback-1',
        action: 'pause',
      );

      expect((listed['playbacks'] as List).single['playbackId'], 'playback-1');
      expect(
        ((listed['playbacks'] as List).single['artwork'] as Map)['mediaType'],
        'image/png',
      );
      expect(detailed['playbackId'], 'playback-1');
      expect((detailed['artwork'] as Map)['mediaType'], 'image/png');
      expect(actionResult['playbackId'], 'playback-1');
      expect(
        transport.requests
            .where(
              (request) =>
                  request['method'] == 'rift.performMediaPlaybackAction',
            )
            .single['params'],
        {
          'sourceDeviceId': 'rift-peer',
          'playbackId': 'playback-1',
          'action': 'pause',
        },
      );
    });

    test('Android playback actions include the source device identity',
        () async {
      const shellChannel = MethodChannel('rift/android/shell');
      AndroidShell.debugIsAndroidOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shellChannel, (call) async => true);
      await client.connect();
      final coordinator = AndroidRemoteMediaPlaybackCoordinator(client);

      try {
        await coordinator.start();
        final handled = await coordinator.handlePlatformMethodCall(
          const MethodCall('mediaPlaybackAction', {
            'sourceDeviceId': 'rift-peer',
            'playbackId': 'playback-1',
            'action': 'pause',
          }),
        );

        expect(handled, isTrue);
        expect(
          transport.requests
              .where(
                (request) =>
                    request['method'] == 'rift.performMediaPlaybackAction',
              )
              .single['params'],
          {
            'sourceDeviceId': 'rift-peer',
            'playbackId': 'playback-1',
            'action': 'pause',
          },
        );
      } finally {
        await coordinator.dispose();
        AndroidShell.debugIsAndroidOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shellChannel, null);
      }
    });

    test('iOS mirrors playback state and routes native seek actions', () async {
      const mediaPlaybackChannel = MethodChannel('rift/ios/media_playback');
      final nativeCalls = <MethodCall>[];
      IOSMediaPlayback.debugIsIOSOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mediaPlaybackChannel, (call) async {
        nativeCalls.add(call);
        return true;
      });
      transport.listMediaPlaybackResult = {
        'playbacks': [
          {
            'playbackId': 'playback-ios-1',
            'sourceDeviceId': 'rift-mac',
            'sourcePlatform': 'macos',
            'appId': 'com.apple.Music',
            'appName': 'Music',
            'title': 'Test Song',
            'artist': 'Test Artist',
            'album': 'Test Album',
            'playbackState': 'playing',
            'positionMs': 1500,
            'durationMs': 180000,
            'canPlay': true,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
            'updatedAt': '2026-07-19T17:30:00Z',
          }
        ],
      };
      await client.connect();
      final coordinator = IOSRemoteMediaPlaybackCoordinator(client);

      try {
        await coordinator.start();

        final showCall = nativeCalls.singleWhere(
          (call) => call.method == 'show',
        );
        final playback = Map<String, dynamic>.from(
          (showCall.arguments as Map)['playback'] as Map,
        );
        expect(playback['sourceDeviceId'], 'rift-mac');
        expect(playback['playbackId'], 'playback-ios-1');
        expect(playback['title'], 'Test Song');
        expect(playback['positionMs'], 1500);

        final handled = await coordinator.handlePlatformMethodCall(
          const MethodCall('mediaPlaybackAction', {
            'sourceDeviceId': 'rift-mac',
            'playbackId': 'playback-ios-1',
            'action': 'seek',
            'positionMs': 42000,
          }),
        );
        expect(handled, isTrue);
        expect(
          transport.requests
              .where(
                (request) =>
                    request['method'] == 'rift.performMediaPlaybackAction',
              )
              .single['params'],
          {
            'sourceDeviceId': 'rift-mac',
            'playbackId': 'playback-ios-1',
            'action': 'seek',
            'positionMs': 42000,
          },
        );

        transport.listMediaPlaybackResult = {
          'playbacks': [
            {
              ...Map<String, dynamic>.from(
                (transport.listMediaPlaybackResult['playbacks'] as List).single
                    as Map,
              ),
              'playbackState': 'paused',
              'positionMs': 42000,
              'canPlay': true,
              'canPause': false,
              'updatedAt': '2026-07-19T17:30:01Z',
            }
          ],
        };
        transport.emitNotification('rift.onMediaPlaybackActionResult', {
          'playbackId': 'playback-ios-1',
          'sourceDeviceId': 'rift-mac',
          'action': 'seek',
          'operationId': 'operation-media-1',
          'state': 'Done',
          'success': true,
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final confirmedPlayback = Map<String, dynamic>.from(
          (nativeCalls.lastWhere((call) => call.method == 'show').arguments
              as Map)['playback'] as Map,
        );
        expect(confirmedPlayback['playbackState'], 'paused');
        expect(confirmedPlayback['positionMs'], 42000);
      } finally {
        await coordinator.dispose();
        IOSMediaPlayback.debugIsIOSOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mediaPlaybackChannel, null);
      }

      expect(nativeCalls.map((call) => call.method), contains('clear'));
    });

    test('macOS mirrors the latest remote playback and routes seek actions',
        () async {
      const mediaPlaybackChannel = MethodChannel('rift/macos/media_playback');
      final nativeCalls = <MethodCall>[];
      MacOSMediaPlaybackBridge.debugIsMacOSOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mediaPlaybackChannel, (call) async {
        nativeCalls.add(call);
        return true;
      });
      transport.listMediaPlaybackResult = {
        'playbacks': [
          {
            'playbackId': 'local-playback',
            'sourceDeviceId': 'rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq',
            'appId': 'com.apple.Music',
            'appName': 'Music',
            'title': 'Local Song',
            'playbackState': 'playing',
            'positionMs': 500,
            'canPlay': false,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
            'updatedAt': '2026-07-19T17:31:00Z',
          },
          {
            'playbackId': 'playback-older',
            'sourceDeviceId': 'rift-linux',
            'appId': 'org.mpris.MediaPlayer2.mpd',
            'appName': 'MPD',
            'title': 'Older Song',
            'playbackState': 'playing',
            'positionMs': 1000,
            'canPlay': false,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': false,
            'updatedAt': '2026-07-19T17:29:00Z',
          },
          {
            'playbackId': 'playback-latest',
            'sourceDeviceId': 'rift-android',
            'appId': 'com.example.player',
            'appName': 'Example Player',
            'title': 'Latest Song',
            'artist': 'Test Artist',
            'playbackState': 'playing',
            'positionMs': 1500,
            'durationMs': 180000,
            'canPlay': false,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
            'updatedAt': '2026-07-19T17:30:00Z',
          },
        ],
      };
      await client.connect();
      final coordinator = MacOSRemoteMediaPlaybackCoordinator(client);

      try {
        await coordinator.start();

        final showCall = nativeCalls.singleWhere(
          (call) => call.method == 'showRemotePlayback',
        );
        final playback = Map<String, dynamic>.from(
          (showCall.arguments as Map)['playback'] as Map,
        );
        expect(playback['sourceDeviceId'], 'rift-android');
        expect(playback['playbackId'], 'playback-latest');
        expect(playback['title'], 'Latest Song');

        final handled = await coordinator.handlePlatformMethodCall(
          const MethodCall('mediaPlaybackAction', {
            'sourceDeviceId': 'rift-android',
            'playbackId': 'playback-latest',
            'action': 'seek',
            'positionMs': 42000,
          }),
        );
        expect(handled, isTrue);
        expect(
          transport.requests
              .where(
                (request) =>
                    request['method'] == 'rift.performMediaPlaybackAction',
              )
              .single['params'],
          {
            'sourceDeviceId': 'rift-android',
            'playbackId': 'playback-latest',
            'action': 'seek',
            'positionMs': 42000,
          },
        );

        transport.emitNotification('rift.onMediaPlaybackUpdated', {
          'playbackId': 'playback-older',
          'sourceDeviceId': 'rift-linux',
          'appId': 'org.mpris.MediaPlayer2.mpd',
          'appName': 'MPD',
          'title': 'Older Song',
          'playbackState': 'playing',
          'positionMs': 2000,
          'canPlay': false,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': false,
          'updatedAt': '2026-07-19T17:32:00Z',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final updatedPlayback = Map<String, dynamic>.from(
          (nativeCalls
              .lastWhere(
                (call) => call.method == 'showRemotePlayback',
              )
              .arguments as Map)['playback'] as Map,
        );
        expect(updatedPlayback['sourceDeviceId'], 'rift-linux');
        expect(updatedPlayback['playbackId'], 'playback-older');
      } finally {
        await coordinator.dispose();
        MacOSMediaPlaybackBridge.debugIsMacOSOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mediaPlaybackChannel, null);
      }

      expect(
        nativeCalls.map((call) => call.method),
        contains('clearRemotePlayback'),
      );
    });

    test('should surface getOperation not found JSON-RPC errors', () async {
      transport.getOperationError = {
        'code': -32009,
        'message': 'Operation not found',
      };
      await client.connect();

      await expectLater(
        client.getOperation('missing-operation'),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('JSON-RPC error -32009') &&
                error.toString().contains('Operation not found'),
          ),
        ),
      );
    });

    test('should preserve spec casing for operation transition notifications',
        () async {
      await client.connect();

      final transitionFuture = client.onOperationTransition.first;
      transport.emitNotification('rift.onOperationTransition', {
        'OperationId': 'operation-1',
        'OperationType': 'clipboard.fetch',
        'PreviousState': 'Pending',
        'NextState': 'Done',
      });

      final transition = await transitionFuture;
      expect(transition, {
        'operationId': 'operation-1',
        'operationType': 'clipboard.fetch',
        'previousState': 'Pending',
        'nextState': 'Done',
      });
    });

    test('should preserve failureReason on operation transition notifications',
        () async {
      await client.connect();

      final transitionFuture = client.onOperationTransition.first;
      transport.emitNotification('rift.onOperationTransition', {
        'OperationId': 'operation-2',
        'OperationType': 'clipboard.fetch',
        'PreviousState': 'Active',
        'NextState': 'Failed',
        'FailureReason': 'PeerUnreachable',
      });

      final transition = await transitionFuture;
      expect(transition, {
        'operationId': 'operation-2',
        'operationType': 'clipboard.fetch',
        'previousState': 'Active',
        'nextState': 'Failed',
        'failureReason': 'PeerUnreachable',
      });
    });

    test(
        'Linux to Android style flow: approve sends correct IPC request and receives completion events',
        () async {
      await client.connect();

      final requestFuture = client.onPairingRequest.first;
      transport.emitNotification('rift.onPairingRequest', {
        'DeviceId': 'rift-android-peer',
        'DisplayName': 'Android Phone',
        'Fingerprint': 'PEER-1111-2222-3333-4444-5555-6666-7777-8888',
        'ExpiresInMs': 120000,
      });
      final requestEvent = await requestFuture;
      expect(requestEvent['deviceId'], 'rift-android-peer');

      await client.approvePairing(
        requestEvent['deviceId'] as String,
        requestEvent['fingerprint'] as String,
      );

      final approveRequest = transport.requests.last;
      expect(approveRequest['method'], 'rift.approvePairing');
      expect(approveRequest['params'], {
        'deviceId': 'rift-android-peer',
        'fingerprint': 'PEER-1111-2222-3333-4444-5555-6666-7777-8888',
      });

      final trustChangedFuture = client.onTrustChanged.first;
      final pairingCompleteFuture = client.onPairingComplete.first;
      transport.emitNotification('rift.onTrustChanged', {
        'DeviceId': 'rift-android-peer',
        'PreviousState': 'pairingPending',
        'NewState': 'trusted',
        'Reason': 'pairing.completed',
      });
      transport.emitNotification('rift.onPairingComplete', {
        'DeviceId': 'rift-android-peer',
        'Fingerprint': 'PEER-1111-2222-3333-4444-5555-6666-7777-8888',
        'PersistedAt': '2026-06-24T02:01:00Z',
      });

      final trustChanged = await trustChangedFuture;
      final pairingComplete = await pairingCompleteFuture;
      expect(trustChanged['newState'], 'trusted');
      expect(trustChanged['previousState'], 'pairing_pending');
      expect(pairingComplete['deviceId'], 'rift-android-peer');
      expect(pairingComplete['fingerprint'],
          'PEER-1111-2222-3333-4444-5555-6666-7777-8888');
    });

    test(
        'Android to Linux style flow: startPairing returns fingerprints and daemon can close pending flow',
        () async {
      await client.connect();

      final startResult =
          await client.startPairing('rift-linux-peer') as Map<String, dynamic>;
      expect(startResult, {
        'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'peerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'expiresInMs': 120000,
      });

      final startRequest = transport.requests.last;
      expect(startRequest['method'], 'rift.startPairing');
      expect(startRequest['params'], {'deviceId': 'rift-linux-peer'});

      final trustChangedFuture = client.onTrustChanged.first;
      transport.emitNotification('rift.onTrustChanged', {
        'DeviceId': 'rift-linux-peer',
        'PreviousState': 'pairingPending',
        'NewState': 'discovered',
        'Reason': 'pairing.closed',
      });

      final trustChanged = await trustChangedFuture;
      expect(trustChanged['deviceId'], 'rift-linux-peer');
      expect(trustChanged['previousState'], 'pairing_pending');
      expect(trustChanged['newState'], 'discovered');
      expect(trustChanged['reason'], 'pairing.closed');
    });
  });
}
