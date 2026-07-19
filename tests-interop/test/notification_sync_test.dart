import 'dart:io';

import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('Simulated notification sync interop', () {
    late Directory tempDir;
    late RiftDaemon daemon;
    late List<Map<String, dynamic>> ipcEvents;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'rift_notification_interop',
      );
      ipcEvents = <Map<String, dynamic>>[];
      daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
        onIpcEvent: ipcEvents.add,
      );
      await daemon.start();
    });

    tearDown(() async {
      await daemon.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    void configurePeer(String peerDeviceId) {
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

    Map<String, dynamic> postedEnvelope(String sourceDeviceId) => {
      'type': 'notification.posted',
      'payload': {
        'notificationId': 'shared-notification-id',
        'sourceDeviceId': sourceDeviceId,
        'sourcePlatform': 'android',
        'packageName': 'com.example.chat',
        'appName': 'Example Chat',
        'title': 'Message',
        'bodyPreview': 'Hello',
        'postedAt': '2026-07-20T10:00:00.000Z',
        'isDismissible': true,
        'isOpenable': false,
      },
    };

    test('keeps notification identity scoped to its Android source', () async {
      const firstPeer = 'rift-first-android';
      const secondPeer = 'rift-second-android';
      configurePeer(firstPeer);
      configurePeer(secondPeer);

      await daemon.handleNotificationSyncProtocolMessageForTesting(
        firstPeer,
        postedEnvelope(firstPeer),
      );
      await daemon.handleNotificationSyncProtocolMessageForTesting(
        secondPeer,
        postedEnvelope(secondPeer),
      );

      var state = await daemon.handleJsonRpcRequest({
        'method': 'rift.listNotifications',
      });
      expect(state['notifications'], hasLength(2));

      await daemon.handleNotificationSyncProtocolMessageForTesting(firstPeer, {
        'type': 'notification.removed',
        'payload': {
          'notificationId': 'shared-notification-id',
          'sourceDeviceId': firstPeer,
          'removedAt': '2026-07-20T10:01:00.000Z',
        },
      });

      state = await daemon.handleJsonRpcRequest({
        'method': 'rift.listNotifications',
      });
      final remaining = (state['notifications'] as List).single as Map;
      expect(remaining['sourceDeviceId'], secondPeer);

      await daemon.handleNotificationSyncProtocolMessageForTesting(firstPeer, {
        ...postedEnvelope(firstPeer),
        'payload': {
          ...(postedEnvelope(firstPeer)['payload'] as Map<String, dynamic>),
          'sourceDeviceId': secondPeer,
        },
      });

      state = await daemon.handleJsonRpcRequest({
        'method': 'rift.listNotifications',
      });
      expect(state['notifications'], hasLength(1));
    });

    test('delivers only supported Android dismiss actions', () async {
      const desktopPeer = 'rift-desktop-peer';
      configurePeer(desktopPeer);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'] as String;

      await daemon.handleJsonRpcRequest({
        'method': 'rift.notifyLocalNotificationEvent',
        'params': {
          'eventType': 'posted',
          'notificationId': 'android-notification-1',
          'packageName': 'com.example.chat',
          'appName': 'Example Chat',
          'postedAt': '2026-07-20T10:00:00.000Z',
          'isDismissible': true,
          'isOpenable': true,
        },
      });

      final state = await daemon.handleJsonRpcRequest({
        'method': 'rift.listNotifications',
      });
      final notification = (state['notifications'] as List).single as Map;
      expect(notification['isDismissible'], isTrue);
      expect(notification['isOpenable'], isFalse);

      await daemon.handleNotificationSyncProtocolMessageForTesting(
        desktopPeer,
        {
          'type': 'notification.actionRequest',
          'payload': {
            'notificationId': 'android-notification-1',
            'sourceDeviceId': localDeviceId,
            'requestingDeviceId': desktopPeer,
            'action': 'dismiss',
          },
        },
      );

      final request = ipcEvents.singleWhere(
        (event) => event['method'] == 'rift.onNotificationActionRequest',
      );
      expect((request['params'] as Map)['action'], 'dismiss');
    });
  });
}
