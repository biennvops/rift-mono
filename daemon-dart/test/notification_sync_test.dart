import 'dart:io';

import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('RiftDaemon notification sync', () {
    test('replays active notifications as updates', () {
      final record = <String, dynamic>{
        'notificationId': 'android:com.example.chat:42',
        'sourceDeviceId': 'rift-local',
      };

      final message = RiftDaemon.buildNotificationReplayMessage(
        localDeviceId: 'rift-local',
        peerDeviceId: 'rift-peer',
        record: record,
      );

      expect(message['type'], 'notification.updated');
      expect(message['sourceDeviceId'], 'rift-local');
      expect(message['destinationDeviceId'], 'rift-peer');
      expect(message['payload'], same(record));
    });

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
      );
      await daemon.start();
    });

    tearDown(() async {
      await daemon.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

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
      expect((listed['policy'] as Map), {
        'enabled': true,
        'mode': 'all',
        'packageNames': <String>[],
      });
    });

    test('normalizes local Android capabilities for remote actions', () async {
      await daemon.handleJsonRpcRequest({
        'method': 'rift.notifyLocalNotificationEvent',
        'params': {
          'eventType': 'posted',
          'notificationId': 'android-local-1',
          'packageName': 'com.example.chat',
          'appName': 'Example Chat',
          'sourcePlatform': 'android',
          'postedAt': '2026-07-15T08:30:00.000Z',
          'isDismissible': true,
          'isOpenable': true,
        },
      });

      final listed = await daemon.handleJsonRpcRequest({
        'method': 'rift.listNotifications',
      });
      final notification =
          (listed['notifications'] as List).single as Map<String, dynamic>;
      expect(notification['isDismissible'], isTrue);
      expect(notification['isOpenable'], isFalse);
    });

    test('notification actions require sourceDeviceId', () async {
      await expectLater(
        daemon.handleJsonRpcRequest({
          'method': 'rift.performNotificationAction',
          'params': {'notificationId': 'notification-1', 'action': 'dismiss'},
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'valid incoming Android dismiss emits a native action request',
      () async {
        const peerDeviceId = 'rift-desktop';
        final context =
            SessionContext(peerDeviceId: peerDeviceId, isInitiator: false)
              ..handshakeState = HandshakeState.established
              ..trustState = TrustState.trusted
              ..capabilityNegotiated = true
              ..negotiatedCapabilities = [
                Capability(name: 'notification.sync', version: 1),
              ];
        daemon.sessionManagerForTesting.injectContextForTesting(context);

        await daemon.handleJsonRpcRequest({
          'method': 'rift.notifyLocalNotificationEvent',
          'params': {
            'eventType': 'posted',
            'notificationId': 'android-local-action',
            'packageName': 'com.example.chat',
            'appName': 'Example Chat',
            'sourcePlatform': 'android',
            'postedAt': '2026-07-15T08:30:00.000Z',
            'isDismissible': true,
            'isOpenable': false,
          },
        });

        final localDeviceId = daemon.getDeviceInfo()['deviceId'];
        await daemon.handleNotificationSyncProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'notification.actionRequest',
            'payload': {
              'notificationId': 'android-local-action',
              'sourceDeviceId': localDeviceId,
              'requestingDeviceId': peerDeviceId,
              'action': 'dismiss',
              'requestedAt': '2026-07-15T08:31:00.000Z',
            },
          },
        );

        final event = ipcEvents.singleWhere(
          (event) => event['method'] == 'rift.onNotificationActionRequest',
        );
        expect(event['params']['notificationId'], 'android-local-action');
        expect(event['params']['sourceDeviceId'], localDeviceId);
        expect(event['params']['requestingDeviceId'], peerDeviceId);
        expect(event['params']['action'], 'dismiss');
      },
    );

    test(
      'accepts legacy blacklist requests and keeps suppressed notifications local',
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
        final policy = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'rift.listNotifications',
        });
        expect(policy['policy'], {
          'enabled': true,
          'mode': 'exclude',
          'packageNames': ['com.bank.example'],
        });

        final removed = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'rift.notifyLocalNotificationEvent',
          'params': {
            'eventType': 'removed',
            'notificationId': 'android:com.bank.example:7',
            'removedAt': '2026-07-15T08:31:00.000Z',
          },
        });

        expect(removed['notificationId'], 'android:com.bank.example:7');

        final listed = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 5,
          'method': 'rift.listNotifications',
        });

        expect(listed['notifications'], isEmpty);
      },
    );

    test('applies all, exclude, include, and disabled policy modes', () async {
      Future<Map<String, dynamic>> update(
        bool enabled,
        String mode,
        List<String> packageNames,
      ) {
        return daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 10,
          'method': 'rift.updateNotificationSyncPolicy',
          'params': {
            'enabled': enabled,
            'mode': mode,
            'packageNames': packageNames,
          },
        });
      }

      Future<Map<String, dynamic>> notify(
        String notificationId,
        String packageName,
      ) {
        return daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': notificationId,
          'method': 'rift.notifyLocalNotificationEvent',
          'params': {
            'eventType': 'posted',
            'notificationId': notificationId,
            'packageName': packageName,
            'appName': packageName,
            'postedAt': '2026-07-15T08:30:00.000Z',
            'isDismissible': true,
            'isOpenable': false,
          },
        });
      }

      await update(true, 'all', ['com.blocked']);
      expect((await notify('all', 'com.any'))['suppressed'], isFalse);

      await update(true, 'exclude', ['com.blocked']);
      expect(
        (await notify('exclude-blocked', 'com.blocked'))['suppressed'],
        isTrue,
      );
      expect(
        (await notify('exclude-other', 'com.other'))['suppressed'],
        isFalse,
      );

      await update(true, 'include', ['com.allowed']);
      expect(
        (await notify('include-allowed', 'com.allowed'))['suppressed'],
        isFalse,
      );
      expect(
        (await notify('include-other', 'com.other-2'))['suppressed'],
        isTrue,
      );

      await update(true, 'include', []);
      expect((await notify('include-empty', 'com.any'))['suppressed'], isTrue);

      await update(false, 'all', []);
      expect((await notify('disabled', 'com.allowed'))['suppressed'], isTrue);
    });

    test('records observed apps before include filtering', () async {
      await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 21,
        'method': 'rift.updateNotificationSyncPolicy',
        'params': {
          'enabled': true,
          'mode': 'include',
          'packageNames': <String>[],
        },
      });
      final posted = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 22,
        'method': 'rift.notifyLocalNotificationEvent',
        'params': {
          'eventType': 'posted',
          'notificationId': 'telegram-1',
          'packageName': 'org.telegram.messenger',
          'appName': 'Telegram',
          'postedAt': '2026-07-15T08:30:00.000Z',
          'isDismissible': true,
          'isOpenable': false,
        },
      });

      expect(posted['suppressed'], isTrue);
      final listed = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 23,
        'method': 'rift.listNotifications',
      });
      expect(listed['notifications'], isEmpty);
      expect(listed['observedApps'], [
        {'packageName': 'org.telegram.messenger', 'appName': 'Telegram'},
      ]);
    });

    test(
      'normalizes canonical policy package names and returns canonical JSON',
      () async {
        final result = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 20,
          'method': 'rift.updateNotificationSyncPolicy',
          'params': {
            'enabled': true,
            'mode': 'exclude',
            'packageNames': [' com.foo ', 'com.bar', 'com.foo', ''],
          },
        });

        expect(result, {
          'enabled': true,
          'mode': 'exclude',
          'packageNames': ['com.bar', 'com.foo'],
        });
      },
    );

    test(
      'rejects invalid and ambiguous policy requests as invalid params',
      () async {
        expect(
          daemon.handleJsonRpcRequest({
            'jsonrpc': '2.0',
            'id': 30,
            'method': 'rift.updateNotificationSyncPolicy',
            'params': {
              'enabled': true,
              'mode': 'banana',
              'packageNames': <String>[],
            },
          }),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          daemon.handleJsonRpcRequest({
            'jsonrpc': '2.0',
            'id': 31,
            'method': 'rift.updateNotificationSyncPolicy',
            'params': {
              'enabled': true,
              'mode': 'include',
              'packageNames': ['com.foo'],
              'blacklistedPackages': ['com.bar'],
            },
          }),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}
