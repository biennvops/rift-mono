import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ipc/json_rpc_client.dart';
import '../notification_icon.dart';
import '../notification_sync_policy.dart';
import '../platform/windows_notification_listener.dart';

class WindowsNotificationSyncCoordinator {
  WindowsNotificationSyncCoordinator({
    required JsonRpcRiftClient client,
    Future<void> Function(Map<String, dynamic> event)? publishEvent,
    WindowsNotificationListenerPlatform? listener,
    Future<String?> Function()? getLocalDeviceId,
    Duration pollInterval = const Duration(seconds: 2),
  })  : _client = client,
        _listener = listener ?? WindowsNotificationListener.platform,
        _publishEvent = publishEvent,
        _getLocalDeviceId = getLocalDeviceId,
        _pollInterval = pollInterval;

  final JsonRpcRiftClient _client;
  final WindowsNotificationListenerPlatform _listener;
  final Future<void> Function(Map<String, dynamic> event)? _publishEvent;
  final Future<String?> Function()? _getLocalDeviceId;
  final Duration _pollInterval;
  final Map<String, Map<String, dynamic>> _tracked =
      <String, Map<String, dynamic>>{};
  final Set<String> _incompleteSnapshotIds = <String>{};

  Future<void> _operationQueue = Future<void>.value();
  StreamSubscription<Map<String, dynamic>>? _actionRequestSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _pollTimer;
  WindowsNotificationListenerRuntimeStatus? _runtime;
  bool _running = false;
  bool _ownsActionExecutor = false;
  bool _nativeActionCapabilityAvailable = false;
  bool _hasSuccessfulSnapshot = false;
  bool _pollQueued = false;
  bool _disposed = false;

  bool get isRunning => _running;
  WindowsNotificationListenerRuntimeStatus? get runtimeStatus => _runtime;

  Future<void> start() {
    _ensureActionRequestSubscription();
    return _enqueue(_startOrStop);
  }

  Future<void> refresh() {
    _ensureActionRequestSubscription();
    return _enqueue(_startOrStop);
  }

  Future<void> reconcile() => _enqueue(_reconcileIfRunning);

  Future<void> dispose() async {
    _disposed = true;
    final actionSubscription = _actionRequestSubscription;
    _actionRequestSubscription = null;
    await actionSubscription?.cancel();
    final connectionSubscription = _connectionSubscription;
    _connectionSubscription = null;
    await connectionSubscription?.cancel();
    await _enqueue(() async {
      await _stopInternal();
    });
  }

  void _ensureActionRequestSubscription() {
    if (_disposed) {
      return;
    }
    _actionRequestSubscription ??=
        _client.onNotificationActionRequest.listen((request) {
      unawaited(_enqueue(() => _handleActionRequest(request)));
    });
    _connectionSubscription ??= _client.onConnectionChanged.listen((connected) {
      if (!connected) {
        _ownsActionExecutor = false;
        _nativeActionCapabilityAvailable = false;
        unawaited(_enqueue(
          () => _downgradeTrackedCapabilities(publish: false),
        ));
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operationQueue.then<void>(
      (_) => operation(),
      onError: (Object error, StackTrace stackTrace) {
        return operation();
      },
    );
    _operationQueue = next;
    return next;
  }

  Future<void> _startOrStop() async {
    if (_disposed || !_listener.isSupported) {
      await _stopInternal();
      return;
    }

    final runtime = await _listener.getRuntimeStatus();
    _runtime = runtime;
    final policy = await loadNotificationSyncPolicyPreferences();
    final accessStatus = await _listener.getAccessStatus();
    if (!runtime.supported ||
        !runtime.hasPackageIdentity ||
        !policy.enabled ||
        accessStatus != 'allowed') {
      debugPrint(
        '[Notification Sync] Windows notification listener prerequisites '
        'unavailable: supported=${runtime.supported}, '
        'packaged=${runtime.hasPackageIdentity}, '
        'policyEnabled=${policy.enabled}, access=$accessStatus.',
      );
      await _stopInternal();
      return;
    }

    try {
      final result = await _client.acquireNotificationActionExecutor();
      if (result is! Map || result['acquired'] != true) {
        debugPrint(
          '[Notification Sync] Notification action executor is owned by '
          'another IPC client.',
        );
        _ownsActionExecutor = false;
        await _stopInternal();
        return;
      }
      _ownsActionExecutor = true;
    } catch (error) {
      debugPrint(
        '[Notification Sync] Failed to acquire notification action executor: '
        '$error',
      );
      await _stopInternal();
      return;
    }

    if (!_running) {
      _running = true;
      _nativeActionCapabilityAvailable = false;
      _pollTimer = Timer.periodic(_pollInterval, (_) => _queuePoll());
    }

    await _reconcileIfRunning(reconcileDaemonState: true);
  }

  Future<void> _stopInternal() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    _nativeActionCapabilityAvailable = false;
    await _downgradeTrackedCapabilities(publish: _client.isConnected);
    _hasSuccessfulSnapshot = false;
    _tracked.clear();
    _incompleteSnapshotIds.clear();
    if (_ownsActionExecutor) {
      _ownsActionExecutor = false;
      try {
        await _client.releaseNotificationActionExecutor();
      } catch (_) {
        // A disconnected IPC session has already released its executor lease.
      }
    }
  }

  Future<bool> _hasAllowedAccess() async {
    try {
      return await _listener.getAccessStatus() == 'allowed';
    } catch (_) {
      return false;
    }
  }

  Future<void> _markNativeActionCapabilityUnavailable() async {
    _nativeActionCapabilityAvailable = false;
    await _downgradeTrackedCapabilities(publish: _client.isConnected);
  }

  Future<void> _downgradeTrackedCapabilities({required bool publish}) async {
    final updates = <Map<String, dynamic>>[];
    for (final entry in _tracked.entries.toList(growable: false)) {
      if (entry.value['isDismissible'] != true) {
        continue;
      }
      final downgraded = Map<String, dynamic>.from(entry.value)
        ..['isDismissible'] = false;
      _tracked[entry.key] = downgraded;
      updates.add(<String, dynamic>{
        ...downgraded,
        'eventType': 'updated',
      });
    }
    if (!publish) {
      return;
    }
    for (final update in updates) {
      try {
        await _publish(update);
      } catch (error) {
        debugPrint(
          '[Notification Sync] Failed to publish Windows action capability '
          'loss: $error',
        );
      }
    }
  }

  void _queuePoll() {
    if (_disposed || !_running || _pollQueued) {
      return;
    }
    _pollQueued = true;
    unawaited(
      _enqueue(_reconcileIfRunning).then<void>(
        (_) => _pollQueued = false,
        onError: (Object error, StackTrace stackTrace) {
          _pollQueued = false;
          debugPrint(
            '[Notification Sync] Windows notification poll failed: $error',
          );
        },
      ),
    );
  }

  Future<void> _reconcileIfRunning({
    bool reconcileDaemonState = false,
  }) async {
    if (_disposed || !_running) {
      return;
    }
    if (!_ownsActionExecutor) {
      _nativeActionCapabilityAvailable = false;
      await _downgradeTrackedCapabilities(publish: false);
      return;
    }

    late final List<Map<String, dynamic>> active;
    try {
      if (await _listener.getAccessStatus() != 'allowed') {
        await _markNativeActionCapabilityUnavailable();
        return;
      }
      active = await _listener.listActiveNotifications();
    } catch (_) {
      await _markNativeActionCapabilityUnavailable();
      return;
    }
    _nativeActionCapabilityAvailable = true;

    final reconcileWithDaemon = reconcileDaemonState || !_hasSuccessfulSnapshot;
    var daemonRecords = <String, dynamic>{};
    if (reconcileWithDaemon) {
      final localDeviceId = await _localDeviceId();
      if (localDeviceId == null || localDeviceId.isEmpty) {
        return;
      }
      daemonRecords = await _loadLocalWindowsRecords(localDeviceId);
    }

    final previous = Map<String, Map<String, dynamic>>.from(_tracked);
    final next = <String, Map<String, dynamic>>{};
    final nextIncompleteIds = <String>{};
    final activeIds = <String>{};

    for (final raw in active) {
      final notificationId = _notificationId(raw);
      if (notificationId == null || raw['isRiftNotification'] == true) {
        continue;
      }
      if (!activeIds.add(notificationId)) {
        continue;
      }
      if (raw['snapshotIncomplete'] == true) {
        nextIncompleteIds.add(notificationId);
        final previousEvent = previous[notificationId];
        if (previousEvent != null) {
          final retained = Map<String, dynamic>.from(previousEvent)
            ..['isDismissible'] = false;
          next[notificationId] = retained;
          if (previousEvent['isDismissible'] == true) {
            await _publish(<String, dynamic>{
              ...retained,
              'eventType': 'updated',
            });
          }
        } else if (daemonRecords.containsKey(notificationId)) {
          next[notificationId] = <String, dynamic>{
            'notificationId': notificationId,
            'snapshotIncomplete': true,
          };
        }
        continue;
      }

      final normalized = _normalizeAdded(raw);
      if (normalized == null) {
        activeIds.remove(notificationId);
        continue;
      }

      final previousEvent = previous[notificationId];
      final event = Map<String, dynamic>.from(normalized);
      event['eventType'] =
          previousEvent != null || daemonRecords.containsKey(notificationId)
              ? 'updated'
              : 'posted';
      next[notificationId] = Map<String, dynamic>.from(normalized);
      if (reconcileWithDaemon ||
          previousEvent == null ||
          !_sameNotification(previousEvent, normalized)) {
        await _publish(event);
      }
    }

    final staleIds = <String>{
      ...previous.keys,
      if (reconcileWithDaemon) ...daemonRecords.keys,
    };
    for (final notificationId in staleIds) {
      if (activeIds.contains(notificationId)) {
        continue;
      }
      await _publish(<String, dynamic>{
        'eventType': 'removed',
        'notificationId': notificationId,
        'sourcePlatform': 'windows',
        'removedAt': _nowUtc(),
      });
    }

    _tracked
      ..clear()
      ..addAll(next);
    _incompleteSnapshotIds
      ..clear()
      ..addAll(nextIncompleteIds);
    _hasSuccessfulSnapshot = true;
  }

  Future<void> _handleActionRequest(Map<String, dynamic> request) async {
    final requestId = _nonEmptyString(request['requestId']);
    if (requestId == null) {
      return;
    }

    var success = false;
    var shouldReconcile = false;
    String? failureReason;
    String? message;
    final sourceDeviceId = _nonEmptyString(request['sourceDeviceId']);
    final notificationId = _nonEmptyString(request['notificationId']);
    final action = _nonEmptyString(request['action']);

    if (_disposed || !_running) {
      failureReason = 'CapabilityUnavailable';
      message = 'The Windows notification observer is not running.';
    } else {
      final localDeviceId = await _localDeviceId();
      if (localDeviceId == null || sourceDeviceId != localDeviceId) {
        failureReason = 'PolicyDenied';
        message = 'The notification action does not target this device.';
      } else if (action != 'dismiss') {
        failureReason = 'PolicyDenied';
        message = 'Windows notification open is not supported.';
      } else if (!_ownsActionExecutor ||
          !_nativeActionCapabilityAvailable ||
          _runtime?.supported != true ||
          _runtime?.hasPackageIdentity != true) {
        failureReason = 'CapabilityUnavailable';
        message = 'The Windows notification observer is unavailable.';
      } else if (!await _hasAllowedAccess()) {
        await _markNativeActionCapabilityUnavailable();
        failureReason = 'CapabilityUnavailable';
        message = 'The Windows notification observer is unavailable.';
      } else {
        final userNotificationId = _parseWindowsNotificationId(notificationId);
        if (userNotificationId == null) {
          failureReason = 'CapabilityUnavailable';
          message = 'The Windows notification ID is invalid.';
        } else if (!await _hasExactTarget(notificationId!)) {
          failureReason = 'CapabilityUnavailable';
          message = 'The Windows notification is no longer available.';
        } else {
          try {
            final result =
                await _listener.removeNotification(userNotificationId);
            success = result.success;
            shouldReconcile = success;
            if (!success) {
              switch (result.status) {
                case WindowsNotificationRemovalStatus.notFound:
                  failureReason = 'CapabilityUnavailable';
                  break;
                case WindowsNotificationRemovalStatus.unavailable:
                  await _markNativeActionCapabilityUnavailable();
                  failureReason = 'CapabilityUnavailable';
                  break;
                case WindowsNotificationRemovalStatus.error:
                  failureReason = 'PeerRejected';
                  break;
                case WindowsNotificationRemovalStatus.success:
                  break;
              }
              message = result.message;
            }
          } catch (_) {
            failureReason = 'PeerRejected';
            message = 'The Windows notification could not be removed.';
          }
        }
      }
    }

    try {
      await _client.reportLocalNotificationActionHandled(
        requestId: requestId,
        success: success,
        failureReason: failureReason,
        message: message,
      );
    } catch (_) {
      // The daemon may already have timed out or disconnected the requester.
    }
    if (shouldReconcile) {
      try {
        await _reconcileIfRunning();
      } catch (_) {
        // A later poll will retry source-state publication.
      }
    }
  }

  int? _parseWindowsNotificationId(String? notificationId) {
    if (notificationId == null ||
        !RegExp(r'^windows:(0|[1-9][0-9]*)$').hasMatch(notificationId)) {
      return null;
    }
    final value = int.tryParse(notificationId.substring('windows:'.length));
    if (value == null || value < 0 || value > 0xffffffff) {
      return null;
    }
    return value;
  }

  Future<bool> _hasExactTarget(String notificationId) async {
    final tracked = _tracked[notificationId];
    if (tracked != null && !_incompleteSnapshotIds.contains(notificationId)) {
      return true;
    }
    try {
      final active = await _listener.listActiveNotifications();
      for (final raw in active) {
        final normalized = _normalizeAdded(raw);
        if (normalized?['notificationId'] == notificationId) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Map<String, dynamic>? _normalizeAdded(Map<String, dynamic> raw) {
    if (raw['isRiftNotification'] == true ||
        raw['snapshotIncomplete'] == true) {
      return null;
    }

    final packageName =
        _nonEmptyString(raw['packageName']) ?? 'windows.unknown';
    final runtime = _runtime;
    if (runtime != null &&
        ((runtime.appUserModelId != null &&
                packageName == runtime.appUserModelId) ||
            (runtime.packageFamilyName != null &&
                packageName == runtime.packageFamilyName))) {
      return null;
    }

    final notificationId = _notificationId(raw);
    if (notificationId == null) {
      return null;
    }

    final appName = _nonEmptyString(raw['appName']) ?? 'Windows application';
    final event = <String, dynamic>{
      'eventType': 'posted',
      'notificationId': notificationId,
      'sourcePlatform': 'windows',
      'packageName': packageName,
      'appName': appName,
      'isDismissible':
          _running && _ownsActionExecutor && _nativeActionCapabilityAvailable,
      'isOpenable': false,
      'postedAt': _nonEmptyString(raw['postedAt']) ??
          _nonEmptyString(_tracked[notificationId]?['postedAt']) ??
          _nowUtc(),
    };

    final title = _nonEmptyString(raw['title']);
    if (title != null) {
      event['title'] = _bound(title, 256);
    }
    final body = _nonEmptyString(raw['bodyPreview']);
    if (body != null) {
      event['bodyPreview'] = _bound(body, 1024);
    }

    final icon = _normalizeIcon(raw);
    if (icon != null) {
      event['icon'] = icon;
    }
    return event;
  }

  Map<String, Object?>? _normalizeIcon(Map<String, dynamic> raw) {
    final bytes = raw['iconBytes'];
    Uint8List? pngBytes;
    if (bytes is Uint8List) {
      pngBytes = bytes;
    } else if (bytes is List<int>) {
      pngBytes = Uint8List.fromList(bytes);
    }
    if (pngBytes != null) {
      return createNotificationIconPayload(pngBytes);
    }

    final icon = raw['icon'];
    if (icon is! Map || parseNotificationIcon(icon) == null) {
      return null;
    }
    return Map<String, Object?>.from(icon);
  }

  String? _notificationId(Map<String, dynamic> raw) {
    final direct = _nonEmptyString(raw['notificationId']);
    if (direct != null) {
      return _parseWindowsNotificationId(direct) == null ? null : direct;
    }
    final userId = raw['userNotificationId'];
    if (userId is int || userId is num) {
      final value = userId is int ? userId : userId.toInt();
      return value < 0 || value > 0xffffffff ? null : 'windows:$value';
    }
    return null;
  }

  Future<Map<String, dynamic>> _loadLocalWindowsRecords(
    String localDeviceId,
  ) async {
    try {
      final result = await _client.listNotifications();
      if (result is! Map || result['notifications'] is! List) {
        return <String, dynamic>{};
      }
      final records = <String, dynamic>{};
      for (final item in result['notifications'] as List) {
        if (item is! Map) {
          continue;
        }
        if (item['sourceDeviceId']?.toString() != localDeviceId ||
            item['sourcePlatform']?.toString() != 'windows') {
          continue;
        }
        final id = _nonEmptyString(item['notificationId']);
        if (id != null) {
          records[id] = Map<String, dynamic>.from(item);
        }
      }
      return records;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<String?> _localDeviceId() async {
    final getLocalDeviceId = _getLocalDeviceId;
    if (getLocalDeviceId != null) {
      return getLocalDeviceId();
    }
    try {
      final result = await _client.getDeviceInfo();
      if (result is Map) {
        return _nonEmptyString(result['deviceId']);
      }
    } catch (_) {
      // The next connection recovery will retry reconciliation.
    }
    return null;
  }

  Future<void> _publish(Map<String, dynamic> event) async {
    final publisher = _publishEvent;
    if (publisher != null) {
      await publisher(event);
      return;
    }
    final eventType = event['eventType']?.toString();
    if (eventType == null || eventType.isEmpty) {
      return;
    }
    await _client.notifyLocalNotificationEvent(
      eventType: eventType,
      payload: Map<String, Object?>.from(event),
    );
  }
}

bool _sameNotification(
  Map<String, dynamic> previous,
  Map<String, dynamic> next,
) {
  if (previous.length != next.length) {
    return false;
  }
  for (final entry in previous.entries) {
    if (!next.containsKey(entry.key) ||
        !_sameNotificationValue(entry.value, next[entry.key])) {
      return false;
    }
  }
  return true;
}

bool _sameNotificationValue(Object? previous, Object? next) {
  if (previous is Map && next is Map) {
    if (previous.length != next.length) {
      return false;
    }
    for (final entry in previous.entries) {
      if (!next.containsKey(entry.key) ||
          !_sameNotificationValue(entry.value, next[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return previous == next;
}

String _nowUtc() => DateTime.now().toUtc().toIso8601String();

String? _nonEmptyString(Object? value) {
  final string = value?.toString().trim();
  return string == null || string.isEmpty ? null : string;
}

String _bound(String value, int maxCharacters) =>
    value.length <= maxCharacters ? value : value.substring(0, maxCharacters);
