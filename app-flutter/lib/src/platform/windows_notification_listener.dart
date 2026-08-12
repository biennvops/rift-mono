import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum WindowsNotificationRemovalStatus {
  success,
  notFound,
  unavailable,
  error,
}

class WindowsNotificationRemovalResult {
  const WindowsNotificationRemovalResult({
    required this.status,
    this.message,
  });

  final WindowsNotificationRemovalStatus status;
  final String? message;

  bool get success => status == WindowsNotificationRemovalStatus.success;

  factory WindowsNotificationRemovalResult.fromMap(Object? value) {
    if (value is! Map) {
      return const WindowsNotificationRemovalResult(
        status: WindowsNotificationRemovalStatus.error,
      );
    }
    final map = Map<Object?, Object?>.from(value);
    final status = switch (map['status']?.toString()) {
      'success' => WindowsNotificationRemovalStatus.success,
      'notFound' => WindowsNotificationRemovalStatus.notFound,
      'unavailable' => WindowsNotificationRemovalStatus.unavailable,
      _ => WindowsNotificationRemovalStatus.error,
    };
    return WindowsNotificationRemovalResult(
      status: status,
      message: _nonEmptyString(map['message']),
    );
  }
}

/// Runtime/access states exposed by the Windows notification source adapter.
enum WindowsNotificationAccessState {
  allowed,
  denied,
  unspecified,
  unsupported,
  unpackaged,
  error,
}

WindowsNotificationAccessState windowsNotificationAccessStateFromWire(
  String value,
) {
  switch (value) {
    case 'allowed':
      return WindowsNotificationAccessState.allowed;
    case 'denied':
      return WindowsNotificationAccessState.denied;
    case 'unspecified':
      return WindowsNotificationAccessState.unspecified;
    case 'unsupported':
      return WindowsNotificationAccessState.unsupported;
    case 'unpackaged':
      return WindowsNotificationAccessState.unpackaged;
    default:
      return WindowsNotificationAccessState.error;
  }
}

String windowsNotificationAccessStateToWire(
  WindowsNotificationAccessState state,
) {
  switch (state) {
    case WindowsNotificationAccessState.allowed:
      return 'allowed';
    case WindowsNotificationAccessState.denied:
      return 'denied';
    case WindowsNotificationAccessState.unspecified:
      return 'unspecified';
    case WindowsNotificationAccessState.unsupported:
      return 'unsupported';
    case WindowsNotificationAccessState.unpackaged:
      return 'unpackaged';
    case WindowsNotificationAccessState.error:
      return 'error';
  }
}

class WindowsNotificationListenerRuntimeStatus {
  const WindowsNotificationListenerRuntimeStatus({
    required this.supported,
    required this.hasPackageIdentity,
    this.appUserModelId,
    this.packageFamilyName,
  });

  final bool supported;
  final bool hasPackageIdentity;
  final String? appUserModelId;
  final String? packageFamilyName;

  factory WindowsNotificationListenerRuntimeStatus.fromMap(Object? value) {
    if (value is! Map) {
      return const WindowsNotificationListenerRuntimeStatus(
        supported: false,
        hasPackageIdentity: false,
      );
    }
    final map = Map<Object?, Object?>.from(value);
    return WindowsNotificationListenerRuntimeStatus(
      supported: map['supported'] == true,
      hasPackageIdentity: map['hasPackageIdentity'] == true,
      appUserModelId: _nonEmptyString(map['appUserModelId']),
      packageFamilyName: _nonEmptyString(map['packageFamilyName']),
    );
  }
}

class WindowsNotificationListenerStatus {
  const WindowsNotificationListenerStatus({
    required this.runtime,
    required this.accessState,
  });

  final WindowsNotificationListenerRuntimeStatus runtime;
  final WindowsNotificationAccessState accessState;

  bool get supported => runtime.supported;
  bool get hasPackageIdentity => runtime.hasPackageIdentity;
  bool get isAllowed => accessState == WindowsNotificationAccessState.allowed;
}

abstract interface class WindowsNotificationListenerPlatform {
  bool get isSupported;

  Future<WindowsNotificationListenerRuntimeStatus> getRuntimeStatus();

  Future<String> getAccessStatus();

  Future<String> requestAccess();

  Future<List<Map<String, dynamic>>> listActiveNotifications();

  Future<WindowsNotificationRemovalResult> removeNotification(
    int userNotificationId,
  );

  Future<bool> start();

  Future<void> stop();

  Stream<Map<String, dynamic>> get events;
}

class MethodChannelWindowsNotificationListener
    implements WindowsNotificationListenerPlatform {
  const MethodChannelWindowsNotificationListener();

  static const MethodChannel methodChannel =
      MethodChannel('rift/windows/notification_listener');
  static const EventChannel eventChannel =
      EventChannel('rift/windows/notification_listener_events');

  @visibleForTesting
  static bool? debugIsWindowsOverride;

  @override
  bool get isSupported => debugIsWindowsOverride ?? Platform.isWindows;

  @override
  Future<WindowsNotificationListenerRuntimeStatus> getRuntimeStatus() async {
    if (!isSupported) {
      return const WindowsNotificationListenerRuntimeStatus(
        supported: false,
        hasPackageIdentity: false,
      );
    }
    try {
      final result =
          await methodChannel.invokeMethod<Object>('getRuntimeStatus');
      return WindowsNotificationListenerRuntimeStatus.fromMap(result);
    } catch (_) {
      return const WindowsNotificationListenerRuntimeStatus(
        supported: false,
        hasPackageIdentity: false,
      );
    }
  }

  @override
  Future<String> getAccessStatus() async {
    if (!isSupported) {
      return 'unsupported';
    }
    final runtime = await getRuntimeStatus();
    if (!runtime.supported) {
      return 'unsupported';
    }
    if (!runtime.hasPackageIdentity) {
      return 'unpackaged';
    }
    try {
      final result = await methodChannel.invokeMethod<Object>(
        'getAccessStatus',
      );
      return _canonicalStatus(result?.toString());
    } catch (_) {
      return 'error';
    }
  }

  @override
  Future<String> requestAccess() async {
    if (!isSupported) {
      return 'unsupported';
    }
    final runtime = await getRuntimeStatus();
    if (!runtime.supported) {
      return 'unsupported';
    }
    if (!runtime.hasPackageIdentity) {
      return 'unpackaged';
    }
    try {
      final result = await methodChannel.invokeMethod<Object>('requestAccess');
      return _canonicalStatus(result?.toString());
    } catch (_) {
      return 'error';
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listActiveNotifications() async {
    if (!isSupported) {
      return const <Map<String, dynamic>>[];
    }
    try {
      final result = await methodChannel.invokeMethod<Object>('listActive');
      if (result is! List) {
        return const <Map<String, dynamic>>[];
      }
      return result
          .whereType<Map>()
          .map((item) => _dynamicMap(item))
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  @override
  Future<WindowsNotificationRemovalResult> removeNotification(
    int userNotificationId,
  ) async {
    if (!isSupported ||
        userNotificationId < 0 ||
        userNotificationId > 0xffffffff) {
      return const WindowsNotificationRemovalResult(
        status: WindowsNotificationRemovalStatus.unavailable,
      );
    }
    final runtime = await getRuntimeStatus();
    if (!runtime.supported || !runtime.hasPackageIdentity) {
      return const WindowsNotificationRemovalResult(
        status: WindowsNotificationRemovalStatus.unavailable,
      );
    }
    if (await getAccessStatus() != 'allowed') {
      return const WindowsNotificationRemovalResult(
        status: WindowsNotificationRemovalStatus.unavailable,
      );
    }
    try {
      final result = await methodChannel.invokeMethod<Object>(
        'removeNotification',
        <String, Object>{'userNotificationId': userNotificationId},
      );
      return WindowsNotificationRemovalResult.fromMap(result);
    } catch (_) {
      return const WindowsNotificationRemovalResult(
        status: WindowsNotificationRemovalStatus.error,
      );
    }
  }

  @override
  Future<bool> start() async {
    if (!isSupported) {
      return false;
    }
    final result = await methodChannel.invokeMethod<Object>('start');
    return result == true;
  }

  @override
  Future<void> stop() async {
    if (isSupported) {
      await methodChannel.invokeMethod<Object>('stop');
    }
  }

  @override
  Stream<Map<String, dynamic>> get events {
    if (!isSupported) {
      return const Stream<Map<String, dynamic>>.empty();
    }
    return eventChannel.receiveBroadcastStream().where((value) {
      return value is Map;
    }).map((value) => _dynamicMap(value as Map));
  }
}

class WindowsNotificationListener {
  WindowsNotificationListener._();

  static const MethodChannel _methodChannel =
      MethodChannelWindowsNotificationListener.methodChannel;
  static WindowsNotificationListenerPlatform _platform =
      const MethodChannelWindowsNotificationListener();

  static WindowsNotificationListenerPlatform get platform => _platform;

  @visibleForTesting
  static set platform(WindowsNotificationListenerPlatform value) {
    _platform = value;
  }

  static bool get isSupported => _platform.isSupported;

  static Future<WindowsNotificationListenerStatus> getStatus() async {
    final runtime = await _platform.getRuntimeStatus();
    if (!runtime.supported) {
      return WindowsNotificationListenerStatus(
        runtime: runtime,
        accessState: WindowsNotificationAccessState.unsupported,
      );
    }
    if (!runtime.hasPackageIdentity) {
      return WindowsNotificationListenerStatus(
        runtime: runtime,
        accessState: WindowsNotificationAccessState.unpackaged,
      );
    }
    final access = await _platform.getAccessStatus();
    return WindowsNotificationListenerStatus(
      runtime: runtime,
      accessState: windowsNotificationAccessStateFromWire(access),
    );
  }

  static Future<String> getAccessStatus() => _platform.getAccessStatus();

  static Future<String> requestAccess() => _platform.requestAccess();

  static Future<List<Map<String, dynamic>>> listActiveNotifications() =>
      _platform.listActiveNotifications();

  static Future<WindowsNotificationRemovalResult> removeNotification(
    int userNotificationId,
  ) =>
      _platform.removeNotification(userNotificationId);

  static Future<void> start() async {
    await _platform.start();
  }

  static Future<void> stop() => _platform.stop();

  static Stream<Map<String, dynamic>> get events => _platform.events;

  // Retained as a named channel for tests and platform integrations that need
  // to verify channel registration without depending on the implementation.
  @visibleForTesting
  static MethodChannel get methodChannel => _methodChannel;
}

String _canonicalStatus(String? value) {
  switch (value) {
    case 'allowed':
    case 'denied':
    case 'unspecified':
    case 'unsupported':
    case 'unpackaged':
    case 'error':
      return value!;
    default:
      return 'error';
  }
}

String? _nonEmptyString(Object? value) {
  final string = value?.toString().trim();
  return string == null || string.isEmpty ? null : string;
}

Map<String, dynamic> _dynamicMap(Map value) {
  return value.map(
    (key, value) => MapEntry(key?.toString() ?? '', _copyNativeValue(value)),
  );
}

Object? _copyNativeValue(Object? value) {
  if (value is Uint8List) {
    return Uint8List.fromList(value);
  }
  if (value is List && value.every((item) => item is int)) {
    return Uint8List.fromList(value.cast<int>());
  }
  if (value is Map) {
    return _dynamicMap(value);
  }
  if (value is List) {
    return value.map(_copyNativeValue).toList(growable: false);
  }
  return value;
}
