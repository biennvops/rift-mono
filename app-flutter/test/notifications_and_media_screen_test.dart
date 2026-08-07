import 'dart:async';

import 'package:rift/screens/notifications_and_media_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class SyncUiClient extends JsonRpcRiftClient {
  SyncUiClient() : super(FakeTransport());

  final postedNotifications =
      StreamController<Map<String, dynamic>>.broadcast();
  final updatedNotifications =
      StreamController<Map<String, dynamic>>.broadcast();
  final removedNotifications =
      StreamController<Map<String, dynamic>>.broadcast();
  final postedMedia = StreamController<Map<String, dynamic>>.broadcast();
  final updatedMedia = StreamController<Map<String, dynamic>>.broadcast();
  final removedMedia = StreamController<Map<String, dynamic>>.broadcast();

  String? notificationAction;
  String? mediaAction;

  @override
  Stream<Map<String, dynamic>> get onNotificationPosted =>
      postedNotifications.stream;

  @override
  Stream<Map<String, dynamic>> get onNotificationUpdated =>
      updatedNotifications.stream;

  @override
  Stream<Map<String, dynamic>> get onNotificationRemoved =>
      removedNotifications.stream;

  @override
  Stream<Map<String, dynamic>> get onMediaPlaybackPosted => postedMedia.stream;

  @override
  Stream<Map<String, dynamic>> get onMediaPlaybackUpdated =>
      updatedMedia.stream;

  @override
  Stream<Map<String, dynamic>> get onMediaPlaybackRemoved =>
      removedMedia.stream;

  @override
  Future<dynamic> listTrustedPeers() async => {
        'peers': [
          {'deviceId': 'rift-peer-1', 'displayName': 'Pixel'}
        ],
      };

  @override
  Future<dynamic> listNotifications() async => {
        'notifications': [
          {
            'notificationId': 'notification-1',
            'sourceDeviceId': 'rift-peer-1',
            'appName': 'Messages',
            'title': 'Alice',
            'bodyPreview': 'Hello',
            'postedAt': '2026-07-29T00:00:00Z',
            'isOpenable': true,
            'isDismissible': true,
          }
        ],
      };

  @override
  Future<dynamic> listMediaPlayback() async => {
        'playbacks': [
          {
            'playbackId': 'playback-1',
            'sourceDeviceId': 'rift-peer-1',
            'appName': 'Music',
            'title': 'A Song',
            'artist': 'An Artist',
            'playbackState': 'playing',
            'positionMs': 30000,
            'durationMs': 120000,
            'canPlay': true,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
          }
        ],
      };

  @override
  Future<dynamic> performNotificationAction({
    required String sourceDeviceId,
    required String notificationId,
    required String action,
  }) async {
    notificationAction = action;
    return {'operationId': 'operation-1'};
  }

  @override
  Future<dynamic> performMediaPlaybackAction({
    required String playbackId,
    required String sourceDeviceId,
    required String action,
    int? positionMs,
  }) async {
    mediaAction = action;
    return {'operationId': 'operation-2'};
  }

  Future<void> closeControllers() async {
    await Future.wait([
      postedNotifications.close(),
      updatedNotifications.close(),
      removedNotifications.close(),
      postedMedia.close(),
      updatedMedia.close(),
      removedMedia.close(),
    ]);
  }
}

void main() {
  testWidgets('shows mirrored notification inbox and performs actions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = SyncUiClient();
    addTearDown(client.closeControllers);

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const MaterialApp(home: NotificationsAndMediaScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Pixel'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pumpAndSettle();
    expect(client.notificationAction, 'open');

    client.updatedNotifications.add({
      'notificationId': 'notification-1',
      'sourceDeviceId': 'rift-peer-1',
      'appName': 'Messages',
      'title': 'Alice',
      'bodyPreview': 'Updated message',
      'postedAt': '2026-07-29T00:01:00Z',
      'isOpenable': true,
      'isDismissible': true,
    });
    await tester.pumpAndSettle();
    expect(find.text('Updated message'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);

    client.removedNotifications.add({
      'notificationId': 'notification-1',
      'sourceDeviceId': 'rift-peer-1',
    });
    await tester.pumpAndSettle();
    expect(find.text('No mirrored notifications'), findsOneWidget);
  });

  testWidgets('shows media sessions and performs supported controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = SyncUiClient();
    addTearDown(client.closeControllers);

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const MaterialApp(home: NotificationsAndMediaScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();

    expect(find.text('A Song'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);

    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(client.mediaAction, 'next');
  });
}
