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

class AndroidBackgroundRuntimeShutdown {
  AndroidBackgroundRuntimeShutdown({
    required FutureOr<void> Function() stopEventProducers,
    required FutureOr<void> Function() disposeRemoteMedia,
    required FutureOr<void> Function() disposeDeviceStatusPublisher,
    required FutureOr<void> Function() disposeClient,
    required FutureOr<void> Function() drainOwnedWork,
    void Function(String message)? logger,
  })  : _stopEventProducers = stopEventProducers,
        _disposeRemoteMedia = disposeRemoteMedia,
        _disposeDeviceStatusPublisher = disposeDeviceStatusPublisher,
        _disposeClient = disposeClient,
        _drainOwnedWork = drainOwnedWork,
        _logger = logger;

  final FutureOr<void> Function() _stopEventProducers;
  final FutureOr<void> Function() _disposeRemoteMedia;
  final FutureOr<void> Function() _disposeDeviceStatusPublisher;
  final FutureOr<void> Function() _disposeClient;
  final FutureOr<void> Function() _drainOwnedWork;
  final void Function(String message)? _logger;
  Future<void>? _shutdownFuture;
  bool _isShuttingDown = false;

  bool get isShuttingDown => _isShuttingDown;

  Future<void> shutdown() {
    _isShuttingDown = true;
    return _shutdownFuture ??= _performShutdown();
  }

  Future<void> _performShutdown() async {
    _logger?.call('Dart runtime shutdown started');
    await _runStep('event producers', _stopEventProducers);
    final remoteMediaDispose = _runStep('remote media', _disposeRemoteMedia);
    final deviceStatusDispose =
        _runStep('device status', _disposeDeviceStatusPublisher);
    await _runStep('JSON-RPC client', _disposeClient);
    await remoteMediaDispose;
    await deviceStatusDispose;
    await _runStep('owned async work', _drainOwnedWork);
    _logger?.call('Dart runtime shutdown complete');
  }

  Future<void> _runStep(
    String owner,
    FutureOr<void> Function() dispose,
  ) async {
    try {
      await dispose();
    } catch (error) {
      _logger?.call('Failed to dispose $owner: $error');
    }
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
  final ownedSubscriptions = <StreamSubscription<dynamic>>[];
  DeviceStatusPublisher? deviceStatusPublisher;
  Future<void>? deviceStatusPublisherStart;
  AndroidRemoteMediaPlaybackCoordinator? remoteMedia;
  Future<void>? remoteMediaStart;
  Future<void>? nativeEventQueueDispose;
  late final AndroidBackgroundRuntimeShutdown runtimeShutdown;

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
    if (runtimeShutdown.isShuttingDown) {
      return AndroidNativeEventDispatchResult.drop;
    }
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
  runtimeShutdown = AndroidBackgroundRuntimeShutdown(
    stopEventProducers: () async {
      nativeEventQueueDispose ??= nativeEventQueue.dispose();
      final subscriptions = List<StreamSubscription<dynamic>>.of(
        ownedSubscriptions,
      );
      ownedSubscriptions.clear();
      for (final subscription in subscriptions) {
        try {
          await subscription.cancel();
        } catch (error) {
          debugPrint(
            '[Android Background] Failed to cancel subscription: $error',
          );
        }
      }
    },
    disposeRemoteMedia: () async {
      final owner = remoteMedia;
      remoteMedia = null;
      await owner?.dispose();
    },
    disposeDeviceStatusPublisher: () async {
      final owner = deviceStatusPublisher;
      deviceStatusPublisher = null;
      await owner?.dispose();
    },
    disposeClient: client.dispose,
    drainOwnedWork: () async {
      try {
        await nativeEventQueueDispose;
      } catch (_) {}
      final remoteStart = remoteMediaStart;
      final deviceStatusStart = deviceStatusPublisherStart;
      remoteMediaStart = null;
      deviceStatusPublisherStart = null;
      try {
        await remoteStart;
      } catch (_) {}
      try {
        await deviceStatusStart;
      } catch (_) {}
      try {
        await mirroredNotificationLifecycleQueue;
      } catch (_) {}
    },
    logger: (message) => debugPrint('[Android Background] $message'),
  );

  Future<void> handleIncomingNotificationAction(
    Map<String, dynamic> request,
  ) async {
    if (runtimeShutdown.isShuttingDown) return;
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
    if (runtimeShutdown.isShuttingDown) return;
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

  ownedSubscriptions.add(
    client.onNotificationActionRequest.listen((request) {
      unawaited(handleIncomingNotificationAction(request));
    }),
  );

  ownedSubscriptions.add(
    client.onMediaPlaybackActionRequest.listen((request) {
      unawaited(handleIncomingMediaPlaybackAction(request));
    }),
  );

  _backgroundBridgeChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'shutdown':
        await runtimeShutdown.shutdown();
        return true;
      case 'uiRequest':
        if (runtimeShutdown.isShuttingDown) return false;
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
        if (runtimeShutdown.isShuttingDown) return false;
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

  try {
    await client.connect();
  } catch (_) {
    if (runtimeShutdown.isShuttingDown) return;
    rethrow;
  }
  if (runtimeShutdown.isShuttingDown) return;
  nativeEventQueue.onConnected();
  Future<void> restorePolicyAndFlushNativeEvents() async {
    if (runtimeShutdown.isShuttingDown) return;
    nativeEventQueue.setNotificationPolicyReady(false);
    await nativeEventQueue.flush();
    if (runtimeShutdown.isShuttingDown) return;
    final restored = await restoreSavedNotificationSyncPolicyBeforeFlush(
      client,
      () async {
        if (runtimeShutdown.isShuttingDown) return;
        nativeEventQueue.setNotificationPolicyReady(true);
        await nativeEventQueue.flush();
      },
    );
    if (runtimeShutdown.isShuttingDown) return;
    nativeEventQueue.setNotificationPolicyReady(restored);
    if (!restored) {
      await nativeEventQueue.flush();
    }
  }

  await restorePolicyAndFlushNativeEvents();
  if (runtimeShutdown.isShuttingDown) return;
  ownedSubscriptions.add(
    transport.rawIncoming.listen((message) {
      if (!runtimeShutdown.isShuttingDown) {
        unawaited(
          _backgroundBridgeChannel.invokeMethod<void>('daemonMessage', message),
        );
      }
    }),
  );
  unawaited(_backgroundBridgeChannel.invokeMethod<void>('backgroundReady'));

  ownedSubscriptions.add(
    client.onConnectionChanged.listen((isConnected) {
      if (runtimeShutdown.isShuttingDown) return;
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
    }),
  );

  deviceStatusPublisher = DeviceStatusPublisher(client);
  deviceStatusPublisherStart = deviceStatusPublisher!.start();
  unawaited(deviceStatusPublisherStart);

  remoteMedia = AndroidRemoteMediaPlaybackCoordinator(client);
  remoteMediaStart = remoteMedia!.start();
  unawaited(remoteMediaStart);

  Future<void> showMirroredNotification(Map<String, dynamic> event) async {
    if (runtimeShutdown.isShuttingDown ||
        event['sourcePlatform']?.toString() == 'android') {
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
    if (runtimeShutdown.isShuttingDown) return;
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

  ownedSubscriptions.add(
    client.onNotificationPosted.listen((event) {
      enqueueMirroredNotificationLifecycle(
        () => showMirroredNotification(event),
      );
    }),
  );
  ownedSubscriptions.add(
    client.onNotificationUpdated.listen((event) {
      enqueueMirroredNotificationLifecycle(
        () => showMirroredNotification(event),
      );
    }),
  );
  ownedSubscriptions.add(
    client.onNotificationRemoved.listen((event) {
      enqueueMirroredNotificationLifecycle(
        () => clearMirroredNotification(event),
      );
    }),
  );

  if (!runtimeShutdown.isShuttingDown) {
    unawaited(
      enqueueMirroredNotificationLifecycle(
        reconcileBackgroundMirroredNotificationPreviews,
      ),
    );
  }
}
