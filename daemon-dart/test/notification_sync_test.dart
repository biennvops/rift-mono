import 'dart:io';

import 'package:daemon_dart/src/daemon.dart';
import 'package:test/test.dart';

void main() {
  group('RiftDaemon notification sync', () {
    late Directory tempDir;
    late RiftDaemon daemon;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rift_notification_sync');
      daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
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
      expect(notifications.single['packageName'], 'com.example.chat');
      expect((listed['policy'] as Map)['enabled'], isTrue);
    });

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
