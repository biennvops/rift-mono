import 'dart:io';

import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('RiftDaemon notification sync', () {
    late Directory tempDir;
    late RiftDaemon daemon;
    late List<Map<String, dynamic>> ipcEvents;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rift_notification_sync');
      ipcEvents = <Map<String, dynamic>>[];
      daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
        onIpcEvent: ipcEvents.add,
        notificationActionTimeout: const Duration(milliseconds: 50),
      );
      await daemon.start();
    });

    tearDown(() async {
      await daemon.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    void configureNotificationPeer(String peerDeviceId) {
      final context =
          SessionContext(peerDeviceId: peerDeviceId, isInitiator: false)
            ..handshakeState = HandshakeState.established
            ..trustState = TrustState.trusted
            ..capabilityNegotiated = true
            ..negotiatedCapabilities = [
              Capability(name: 'notification.sync', version: 1),
            ];
      daemon.sessionManagerForTesting.injectContextForTesting(context);
    }

    test('stores local posted notifications and returns inbox state', () async {
      final result = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'rift.notifyLocalNotificationEvent',
        'params': {
          'eventType': 'posted',
          'notificationId': 'android:com.example.chat:42',
          'packageName': 'com.example.chat',
          'appName': 'Example Chat',
          'sourcePlatform': 'windows',
          'title': 'Riley',
          'bodyPreview': 'See you at 6?',
          'postedAt': '2026-07-15T08:30:00.000Z',
          'isDismissible': true,
          'isOpenable': true,
        },
      });

      expect(result['broadcastTo'], isEmpty);

      final listed = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'rift.listNotifications',
      });

      final notifications = (listed['notifications'] as List)
          .cast<Map<String, dynamic>>();
      expect(notifications, hasLength(1));
      expect(
        notifications.single['notificationId'],
        'android:com.example.chat:42',
      );
      expect(notifications.single['sourcePlatform'], 'windows');
      expect(notifications.single['packageName'], 'com.example.chat');
      expect(notifications.single['isDismissible'], isFalse);
      expect(notifications.single['isOpenable'], isFalse);
      expect((listed['policy'] as Map)['enabled'], isTrue);
    });

    test(
      'delivers Android-origin action requests to the local IPC client',
      () async {
        const peerDeviceId = 'rift-desktop-peer';
        configureNotificationPeer(peerDeviceId);
        final localDeviceId = daemon.getDeviceInfo()['deviceId'];
        await daemon.handleJsonRpcRequest({
          'method': 'rift.notifyLocalNotificationEvent',
          'params': {
            'eventType': 'posted',
            'notificationId': 'android:com.example.chat:42',
            'packageName': 'com.example.chat',
            'appName': 'Example Chat',
            'postedAt': '2026-07-15T08:30:00.000Z',
            'isDismissible': true,
            'isOpenable': true,
          },
        });

        await daemon.handleNotificationSyncProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'notification.actionRequest',
            'payload': {
              'notificationId': 'android:com.example.chat:42',
              'sourceDeviceId': localDeviceId,
              'requestingDeviceId': peerDeviceId,
              'action': 'dismiss',
              'requestedAt': '2026-07-15T08:31:00.000Z',
            },
          },
        );

        final request = ipcEvents.singleWhere(
          (event) => event['method'] == 'rift.onNotificationActionRequest',
        );
        final params = request['params'] as Map<String, dynamic>;
        expect(params['requestId'], isNotEmpty);
        expect(params['notificationId'], 'android:com.example.chat:42');
        expect(params['sourceDeviceId'], localDeviceId);
        expect(params['requestingDeviceId'], peerDeviceId);
        expect(params['action'], 'dismiss');
      },
    );

    test(
      'rejects action requests with mismatched requester identity',
      () async {
        const peerDeviceId = 'rift-desktop-peer';
        configureNotificationPeer(peerDeviceId);
        final localDeviceId = daemon.getDeviceInfo()['deviceId'];
        await daemon.handleJsonRpcRequest({
          'method': 'rift.notifyLocalNotificationEvent',
          'params': {
            'eventType': 'posted',
            'notificationId': 'android:com.example.chat:42',
            'packageName': 'com.example.chat',
            'appName': 'Example Chat',
            'postedAt': '2026-07-15T08:30:00.000Z',
            'isDismissible': true,
            'isOpenable': true,
          },
        });

        await daemon.handleNotificationSyncProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'notification.actionRequest',
            'payload': {
              'notificationId': 'android:com.example.chat:42',
              'sourceDeviceId': localDeviceId,
              'requestingDeviceId': 'rift-spoofed',
              'action': 'open',
            },
          },
        );

        expect(
          ipcEvents.where(
            (event) => event['method'] == 'rift.onNotificationActionRequest',
          ),
          isEmpty,
        );
      },
    );

    test(
      'suppresses broadcast for blacklisted package and removes notifications',
      () async {
        await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'rift.updateNotificationSyncPolicy',
          'params': {
            'enabled': true,
            'blacklistedPackages': ['com.bank.example'],
          },
        });

        final posted = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'rift.notifyLocalNotificationEvent',
          'params': {
            'eventType': 'posted',
            'notificationId': 'android:com.bank.example:7',
            'packageName': 'com.bank.example',
            'appName': 'Bank',
            'postedAt': '2026-07-15T08:30:00.000Z',
            'isDismissible': true,
            'isOpenable': false,
          },
        });

        expect(posted['suppressed'], isTrue);

        await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'rift.notifyLocalNotificationEvent',
          'params': {
            'eventType': 'removed',
            'notificationId': 'android:com.bank.example:7',
            'removedAt': '2026-07-15T08:31:00.000Z',
          },
        });

        final listed = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'rift.listNotifications',
        });

        expect(listed['notifications'], isEmpty);
      },
    );
  });
}
