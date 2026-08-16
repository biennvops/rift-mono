import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;

import '../device_status/device_status_publisher.dart';
import '../media_playback/android_remote_media_playback_coordinator.dart';
import '../notification_sync_policy.dart';
import '../notification_icon.dart';
import '../notification_mirror_identity.dart';
import '../mirrored_notification_registry.dart';
import '../mirrored_notification_reconciliation.dart';
import '../platform/android_shell.dart';
import '../platform/notification_route.dart';
import 'android_daemon_isolate_transport.dart';
import 'android_native_event_queue.dart';
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
  final mirroredNotificationRegistry =
      await MirroredNotificationRegistry.load();
  Future<String?>? localDeviceIdFuture;
  Future<void> mirroredNotificationLifecycleQueue = Future<void>.value();

  Future<void> enqueueMirroredNotificationLifecycle(
    Future<void> Function() operation,
  ) {
    final next = mirroredNotificationLifecycleQueue.then<void>(
      (_) => operation(),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint(
            '[Notification Mirror] Previous lifecycle operation failed: $error');
        return operation();
      },
    );
    mirroredNotificationLifecycleQueue = next;
    unawaited(
      next.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          debugPrint(
              '[Notification Mirror] Lifecycle operation failed: $error');
        },
      ),
    );
    return next;
  }

  Future<String?> getLocalDeviceId() {
    return localDeviceIdFuture ??= () async {
      try {
        final result = await client.getDeviceInfo();
        if (result is Map) {
          final deviceId = result['deviceId']?.toString();
          if (deviceId != null && deviceId.isNotEmpty) {
            return deviceId;
          }
        }
      } catch (_) {
        localDeviceIdFuture = null;
      }
      return null;
    }();
  }

  Future<bool> clearNativeMirroredNotification(String mirrorKey) async {
    try {
      return await AndroidShell.clearNotification(mirrorKey);
    } catch (_) {
      return false;
    }
  }

  Future<void> reconcileBackgroundMirroredNotificationPreviews() {
    return reconcileMirroredNotificationPreviews(
      client: client,
      registry: mirroredNotificationRegistry,
      getLocalDeviceId: getLocalDeviceId,
      clearNativeNotification: clearNativeMirroredNotification,
    );
  }

  Future<AndroidNativeEventDispatchResult> dispatchNativeEvent(
    AndroidNativeEvent event,
  ) async {
    try {
      final payload = Map<String, Object?>.from(event.payload)
        ..remove('eventType');
      switch (event.kind) {
        case AndroidNativeEventKind.notificationState:
          await client.notifyLocalNotificationEvent(
            eventType: event.eventType,
            payload: payload,
          );
          break;
        case AndroidNativeEventKind.mediaPlaybackState:
          await client.notifyLocalMediaPlaybackEvent(
            eventType: event.eventType,
            payload: payload,
          );
          break;
        case AndroidNativeEventKind.mediaPlaybackAction:
          await client.performMediaPlaybackAction(
            sourceDeviceId: event.payload['sourceDeviceId'] as String,
            playbackId: event.payload['playbackId'] as String,
            action: event.payload['action'] as String,
            positionMs: event.payload['positionMs'] as int?,
          );
          break;
      }
      return AndroidNativeEventDispatchResult.delivered;
    } on json_rpc.RpcException {
      return AndroidNativeEventDispatchResult.drop;
    } on StateError {
      return AndroidNativeEventDispatchResult.retryLater;
    } catch (_) {
      return client.isConnected
          ? AndroidNativeEventDispatchResult.drop
          : AndroidNativeEventDispatchResult.retryLater;
    }
  }

  final nativeEventQueue = AndroidNativeEventQueue(
    dispatch: dispatchNativeEvent,
    logger: (message) => debugPrint('[Android Native Event Queue] $message'),
  );

  Future<void> handleIncomingNotificationAction(
    Map<String, dynamic> request,
  ) async {
    final requestId = request['requestId']?.toString();
    final notificationId = request['notificationId']?.toString();
    final action = request['action']?.toString();
    if (requestId == null ||
        requestId.isEmpty ||
        notificationId == null ||
        notificationId.isEmpty ||
        action == null ||
        action.isEmpty) {
      return;
    }

    var success = false;
    String? failureReason;
    String? message;
    try {
      final result = await _backgroundBridgeChannel.invokeMethod<Object?>(
        'performNotificationAction',
        {'notificationId': notificationId, 'action': action},
      );
      if (result is Map) {
        final payload = Map<String, dynamic>.from(result);
        success = payload['success'] == true;
        failureReason = payload['failureReason']?.toString();
        message = payload['message']?.toString();
      } else {
        failureReason = 'CapabilityUnavailable';
        message = 'The Android notification listener is unavailable.';
      }
    } catch (error) {
      failureReason = 'PeerRejected';
      message = error.toString();
    }

    try {
      await client.reportLocalNotificationActionHandled(
        requestId: requestId,
        success: success,
        failureReason: failureReason,
        message: message,
      );
    } catch (_) {
      // The daemon will expire the request if the session has already gone away.
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

  client.onNotificationActionRequest.listen((request) {
    unawaited(handleIncomingNotificationAction(request));
  });

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
          nativeEventQueue.enqueue(Map<String, dynamic>.from(event));
          await nativeEventQueue.flush();
        }
        return true;
      default:
        return null;
    }
  });

  await client.connect();
  nativeEventQueue.onConnected();
  Future<void> restorePolicyAndFlushNativeEvents() async {
    nativeEventQueue.setNotificationPolicyReady(false);
    await nativeEventQueue.flush();
    final restored = await restoreSavedNotificationSyncPolicyBeforeFlush(
      client,
      () async {
        nativeEventQueue.setNotificationPolicyReady(true);
        await nativeEventQueue.flush();
      },
    );
    nativeEventQueue.setNotificationPolicyReady(restored);
    if (!restored) {
      await nativeEventQueue.flush();
    }
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
      nativeEventQueue.onConnected();
      unawaited(restorePolicyAndFlushNativeEvents());
      unawaited(
        enqueueMirroredNotificationLifecycle(
          reconcileBackgroundMirroredNotificationPreviews,
        ),
      );
    } else {
      nativeEventQueue.onConnectionLost();
    }
  });

  final deviceStatusPublisher = DeviceStatusPublisher(client);
  unawaited(deviceStatusPublisher.start());

  final remoteMedia = AndroidRemoteMediaPlaybackCoordinator(client);
  unawaited(remoteMedia.start());

  Future<void> showMirroredNotification(Map<String, dynamic> event) async {
    if (event['sourcePlatform']?.toString() == 'android') {
      return;
    }
    final notificationId = event['notificationId']?.toString();
    final sourceDeviceId = event['sourceDeviceId']?.toString();
    if (notificationId == null ||
        notificationId.isEmpty ||
        sourceDeviceId == null ||
        sourceDeviceId.isEmpty) {
      return;
    }
    final localDeviceId = await getLocalDeviceId();
    if (localDeviceId == null || localDeviceId == sourceDeviceId) {
      return;
    }

    final mirrorKey = mirroredNotificationKey(
      sourceDeviceId: sourceDeviceId,
      notificationId: notificationId,
    );
    final title = event['title']?.toString().trim();
    final body = event['bodyPreview']?.toString().trim();
    final appName = event['appName']?.toString().trim();
    final iconBytes = parseNotificationIcon(event['icon'])?.bytes;
    try {
      final shown = await AndroidShell.showNotification(
        title: title?.isNotEmpty == true
            ? title!
            : (appName?.isNotEmpty == true ? appName! : 'Notification'),
        body: body?.isNotEmpty == true
            ? body!
            : 'Notification from a trusted device.',
        route: NotificationRoute.historyNotifications,
        notificationKey: mirrorKey,
        iconBytes: iconBytes,
        payload: {
          'notificationId': notificationId,
          'sourceDeviceId': sourceDeviceId,
        },
      );
      if (shown) {
        await mirroredNotificationRegistry.remember(
          MirroredNotificationEntry(
            mirrorKey: mirrorKey,
            sourceDeviceId: sourceDeviceId,
            notificationId: notificationId,
          ),
        );
      }
    } catch (_) {
      // Best-effort native preview.
    }
  }

  Future<void> clearMirroredNotification(Map<String, dynamic> event) async {
    final notificationId = event['notificationId']?.toString();
    final sourceDeviceId = event['sourceDeviceId']?.toString();
    if (notificationId == null ||
        notificationId.isEmpty ||
        sourceDeviceId == null ||
        sourceDeviceId.isEmpty) {
      return;
    }
    final localDeviceId = await getLocalDeviceId();
    if (localDeviceId == null || localDeviceId == sourceDeviceId) {
      return;
    }

    final mirrorKey = mirroredNotificationKey(
      sourceDeviceId: sourceDeviceId,
      notificationId: notificationId,
    );
    try {
      if (await clearNativeMirroredNotification(mirrorKey)) {
        await mirroredNotificationRegistry.forget(mirrorKey);
      }
    } catch (_) {
      // Keep the registry entry for a later reconciliation.
    }
  }

  client.onNotificationPosted.listen((event) {
    enqueueMirroredNotificationLifecycle(() => showMirroredNotification(event));
  });
  client.onNotificationUpdated.listen((event) {
    enqueueMirroredNotificationLifecycle(() => showMirroredNotification(event));
  });
  client.onNotificationRemoved.listen((event) {
    enqueueMirroredNotificationLifecycle(
        () => clearMirroredNotification(event));
  });

  unawaited(
    enqueueMirroredNotificationLifecycle(
      reconcileBackgroundMirroredNotificationPreviews,
    ),
  );
}
