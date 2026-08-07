import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../device_status/device_status_publisher.dart';
import '../media_playback/android_remote_media_playback_coordinator.dart';
import '../notification_sync_policy.dart';
import '../platform/android_shell.dart';
import '../platform/notification_route.dart';
import 'android_daemon_isolate_transport.dart';
import 'json_rpc_client.dart';

const _backgroundBridgeChannel =
    MethodChannel('rift/android/background_bridge');

Future<bool> restoreSavedNotificationSyncPolicyBeforeFlush(
  JsonRpcRiftClient client,
  Future<void> Function() flushNativeEvents,
) async {
  try {
    await pushSavedNotificationSyncPolicy(client);
    await flushNativeEvents();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> runAndroidBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  final transport = AndroidDaemonIsolateTransport();
  final client = JsonRpcRiftClient(transport);
  final pendingNativeEvents = <Map<String, dynamic>>[];
  var flushingNativeEvents = false;
  var notificationPolicyReady = false;

  Future<void> flushNativeEvents() async {
    if (flushingNativeEvents || !client.isConnected) {
      return;
    }
    flushingNativeEvents = true;
    try {
      while (pendingNativeEvents.isNotEmpty && client.isConnected) {
        final event = pendingNativeEvents.first;
        final eventType = event['eventType']?.toString();
        if (eventType == null || eventType.isEmpty) {
          pendingNativeEvents.removeAt(0);
          continue;
        }
        final isNotificationPostOrUpdate =
            (eventType == 'posted' || eventType == 'updated') &&
                event.containsKey('notificationId');
        if (isNotificationPostOrUpdate && !notificationPolicyReady) {
          return;
        }
        try {
          if (eventType == 'mediaPlaybackAction') {
            await client.performMediaPlaybackAction(
              sourceDeviceId: event['sourceDeviceId']?.toString() ?? '',
              playbackId: event['playbackId']?.toString() ?? '',
              action: event['action']?.toString() ?? '',
              positionMs: (event['positionMs'] as num?)?.toInt(),
            );
          } else if (eventType == 'posted' ||
              eventType == 'updated' ||
              eventType == 'removed') {
            final payload = Map<String, Object?>.from(event)
              ..remove('eventType');
            if (event.containsKey('notificationId')) {
              await client.notifyLocalNotificationEvent(
                eventType: eventType,
                payload: payload,
              );
            } else if (event.containsKey('playbackId')) {
              await client.notifyLocalMediaPlaybackEvent(
                eventType: eventType,
                payload: payload,
              );
            }
          }
          pendingNativeEvents.removeAt(0);
        } catch (_) {
          return;
        }
      }
    } finally {
      flushingNativeEvents = false;
    }
  }

  Future<void> handleIncomingMediaPlaybackAction(
    Map<String, dynamic> request,
  ) async {
    final requestId = request['requestId']?.toString();
    final playbackId = request['playbackId']?.toString();
    final action = request['action']?.toString();
    if (requestId == null ||
        requestId.isEmpty ||
        playbackId == null ||
        playbackId.isEmpty ||
        action == null ||
        action.isEmpty) {
      return;
    }

    var success = false;
    String? failureReason;
    String? message;
    try {
      final result = await _backgroundBridgeChannel.invokeMethod<Object?>(
        'performMediaPlaybackAction',
        {
          'playbackId': playbackId,
          'action': action,
          if (request['positionMs'] is num)
            'positionMs': (request['positionMs'] as num).toInt(),
        },
      );
      if (result is Map) {
        final payload = Map<String, dynamic>.from(result);
        success = payload['success'] == true;
        failureReason = payload['failureReason']?.toString();
        message = payload['message']?.toString();
      } else {
        failureReason = 'CapabilityUnavailable';
        message = 'The Android media observer is unavailable.';
      }
    } catch (error) {
      failureReason = 'PeerRejected';
      message = error.toString();
    }

    try {
      await client.reportLocalMediaPlaybackActionHandled(
        requestId: requestId,
        success: success,
        failureReason: failureReason,
        message: message,
      );
    } catch (_) {
      // The daemon will expire the request if the session has already gone away.
    }
  }

  client.onMediaPlaybackActionRequest.listen((request) {
    unawaited(handleIncomingMediaPlaybackAction(request));
  });

  _backgroundBridgeChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'uiRequest':
        final message = call.arguments;
        if (message is! String) {
          throw PlatformException(
            code: 'invalid_request',
            message: 'A JSON-RPC request must be a string.',
          );
        }
        await transport.sendRaw(message);
        return true;
      case 'nativeEvent':
        final event = call.arguments;
        if (event is Map) {
          pendingNativeEvents.add(Map<String, dynamic>.from(event));
          await flushNativeEvents();
        }
        return true;
      default:
        return null;
    }
  });

  await client.connect();
  Future<void> restorePolicyAndFlushNativeEvents() async {
    notificationPolicyReady = false;
    final restored = await restoreSavedNotificationSyncPolicyBeforeFlush(
      client,
      () async {
        notificationPolicyReady = true;
        await flushNativeEvents();
      },
    );
    notificationPolicyReady = restored;
  }

  await restorePolicyAndFlushNativeEvents();
  transport.rawIncoming.listen((message) {
    unawaited(
      _backgroundBridgeChannel.invokeMethod<void>('daemonMessage', message),
    );
  });
  _backgroundBridgeChannel.invokeMethod<void>('backgroundReady');

  client.onConnectionChanged.listen((isConnected) {
    if (isConnected) {
      unawaited(restorePolicyAndFlushNativeEvents());
    } else {
      notificationPolicyReady = false;
    }
  });

  final deviceStatusPublisher = DeviceStatusPublisher(client);
  unawaited(deviceStatusPublisher.start());

  final remoteMedia = AndroidRemoteMediaPlaybackCoordinator(client);
  unawaited(remoteMedia.start());

  client.onNotificationPosted.listen((event) {
    if (event['sourcePlatform']?.toString() == 'android') {
      return;
    }
    final title = event['title']?.toString().trim();
    final body = event['bodyPreview']?.toString().trim();
    final appName = event['appName']?.toString().trim();
    unawaited(
      AndroidShell.showNotification(
        title: title?.isNotEmpty == true
            ? title!
            : (appName?.isNotEmpty == true ? appName! : 'Notification'),
        body: body?.isNotEmpty == true
            ? body!
            : 'Notification from a trusted device.',
        route: NotificationRoute.historyNotifications,
        payload: {
          'notificationId': event['notificationId']?.toString(),
          'sourceDeviceId': event['sourceDeviceId']?.toString(),
        },
      ),
    );
  });
}
