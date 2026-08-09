import 'dart:async';
import 'dart:typed_data';

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
  })  : _client = client,
        _listener = listener ?? WindowsNotificationListener.platform,
        _publishEvent = publishEvent,
        _getLocalDeviceId = getLocalDeviceId;

  final JsonRpcRiftClient _client;
  final WindowsNotificationListenerPlatform _listener;
  final Future<void> Function(Map<String, dynamic> event)? _publishEvent;
  final Future<String?> Function()? _getLocalDeviceId;
  final Map<String, Map<String, dynamic>> _tracked =
      <String, Map<String, dynamic>>{};

  Future<void> _operationQueue = Future<void>.value();
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  WindowsNotificationListenerRuntimeStatus? _runtime;
  bool _running = false;
  bool _disposed = false;

  bool get isRunning => _running;
  WindowsNotificationListenerRuntimeStatus? get runtimeStatus => _runtime;

  Future<void> start() => _enqueue(_startOrStop);

  Future<void> refresh() => _enqueue(_startOrStop);

  Future<void> reconcile() => _enqueue(_reconcileIfRunning);

  Future<void> dispose() async {
    _disposed = true;
    await _enqueue(() async {
      await _stopInternal();
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
    if (!runtime.supported ||
        !runtime.hasPackageIdentity ||
        !policy.enabled ||
        await _listener.getAccessStatus() != 'allowed') {
      await _stopInternal();
      return;
    }

    if (!_running) {
      _eventSubscription ??= _listener.events.listen((event) {
        unawaited(_enqueue(() => _handleNativeEvent(event)));
      });
      try {
        final started = await _listener.start();
        if (!started) {
          await _stopInternal();
          return;
        }
        _running = true;
      } catch (_) {
        await _stopInternal();
        return;
      }
    }

    await _reconcileIfRunning();
  }

  Future<void> _stopInternal() async {
    final subscription = _eventSubscription;
    _eventSubscription = null;
    await subscription?.cancel();
    if (_running) {
      try {
        await _listener.stop();
      } catch (_) {
        // Listener cleanup is best effort when the native bridge is going away.
      }
    }
    _running = false;
    _tracked.clear();
  }

  Future<void> _reconcileIfRunning() async {
    if (_disposed || !_running) {
      return;
    }

    final localDeviceId = await _localDeviceId();
    if (localDeviceId == null || localDeviceId.isEmpty) {
      return;
    }

    late final List<Map<String, dynamic>> active;
    try {
      active = await _listener.listActiveNotifications();
    } catch (_) {
      return;
    }
    final daemonRecords = await _loadLocalWindowsRecords(localDeviceId);
    final activeIds = <String>{};

    for (final raw in active) {
      final normalized = _normalizeAdded(raw);
      if (normalized == null) {
        continue;
      }
      final notificationId = normalized['notificationId']!.toString();
      if (!activeIds.add(notificationId)) {
        continue;
      }

      final event = Map<String, dynamic>.from(normalized);
      event['eventType'] = _tracked.containsKey(notificationId) ||
              daemonRecords.containsKey(notificationId)
          ? 'updated'
          : 'posted';
      _tracked[notificationId] = Map<String, dynamic>.from(event);
      await _publish(event);
    }

    for (final entry in daemonRecords.entries) {
      if (activeIds.contains(entry.key)) {
        continue;
      }
      _tracked.remove(entry.key);
      await _publish(<String, dynamic>{
        'eventType': 'removed',
        'notificationId': entry.key,
        'sourcePlatform': 'windows',
        'removedAt': _nowUtc(),
      });
    }
  }

  Future<void> _handleNativeEvent(Map<String, dynamic> raw) async {
    if (_disposed || !_running) {
      return;
    }

    final eventType = raw['eventType']?.toString().trim().toLowerCase();
    if (eventType == 'removed') {
      await _handleRemoved(raw);
      return;
    }
    if (eventType == 'added' ||
        eventType == 'posted' ||
        eventType == 'updated') {
      final normalized = _normalizeAdded(raw);
      if (normalized == null) {
        return;
      }
      final notificationId = normalized['notificationId']!.toString();
      final event = Map<String, dynamic>.from(normalized);
      event['eventType'] =
          _tracked.containsKey(notificationId) || eventType == 'updated'
              ? 'updated'
              : 'posted';
      _tracked[notificationId] = Map<String, dynamic>.from(event);
      await _publish(event);
    }
  }

  Future<void> _handleRemoved(Map<String, dynamic> raw) async {
    final notificationId = _notificationId(raw);
    if (notificationId == null) {
      return;
    }

    final known = (_tracked.remove(notificationId) != null) ||
        await _daemonHasLocalWindowsRecord(notificationId);
    if (!known) {
      return;
    }

    await _publish(<String, dynamic>{
      'eventType': 'removed',
      'notificationId': notificationId,
      'sourcePlatform': 'windows',
      'removedAt': _nonEmptyString(raw['removedAt']) ?? _nowUtc(),
    });
  }

  Map<String, dynamic>? _normalizeAdded(Map<String, dynamic> raw) {
    if (raw['isRiftNotification'] == true) {
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
      'isDismissible': false,
      'isOpenable': false,
      'postedAt': _nonEmptyString(raw['postedAt']) ?? _nowUtc(),
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
      return direct.startsWith('windows:') ? direct : 'windows:$direct';
    }
    final userId = raw['userNotificationId'];
    if (userId is int || userId is num) {
      return 'windows:${userId.toInt()}';
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

  Future<bool> _daemonHasLocalWindowsRecord(String notificationId) async {
    final localDeviceId = await _localDeviceId();
    if (localDeviceId == null || localDeviceId.isEmpty) {
      return false;
    }
    final records = await _loadLocalWindowsRecords(localDeviceId);
    return records.containsKey(notificationId);
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

String _nowUtc() => DateTime.now().toUtc().toIso8601String();

String? _nonEmptyString(Object? value) {
  final string = value?.toString().trim();
  return string == null || string.isEmpty ? null : string;
}

String _bound(String value, int maxCharacters) =>
    value.length <= maxCharacters ? value : value.substring(0, maxCharacters);
