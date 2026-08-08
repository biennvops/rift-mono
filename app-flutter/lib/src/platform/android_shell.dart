import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidShell {
  static const MethodChannel _channel = MethodChannel('rift/android/shell');
  @visibleForTesting
  static bool? debugIsAndroidOverride;

  static bool get isSupported => debugIsAndroidOverride ?? Platform.isAndroid;

  static Future<bool> showNotification({
    required String title,
    required String body,
    required String route,
    String? destinationPath,
    Map<String, Object?>? payload,
    String? notificationKey,
  }) async {
    if (!isSupported) {
      return false;
    }
    final result = await _channel.invokeMethod<bool>('showNotification', {
      'title': title,
      'body': body,
      'route': route,
      if (destinationPath != null) 'destinationPath': destinationPath,
      if (payload != null) 'payload': payload,
      if (notificationKey != null) 'notificationKey': notificationKey,
    });
    return result ?? false;
  }

  static Future<bool> clearNotification(String notificationKey) async {
    if (!isSupported) {
      return false;
    }
    final result = await _channel.invokeMethod<bool>('clearNotification', {
      'notificationKey': notificationKey,
    });
    return result ?? false;
  }

  static Future<Map<dynamic, dynamic>?> prepareIncomingDownload(
    String fileName,
  ) async {
    if (!isSupported) {
      return null;
    }
    final result = await _channel.invokeMethod<dynamic>(
      'prepareIncomingDownload',
      {'fileName': fileName},
    );
    return result is Map ? result : null;
  }

  static Future<Map<dynamic, dynamic>?> publishIncomingDownload({
    required String stagingPath,
    required String fileName,
    required String mediaType,
  }) async {
    if (!isSupported) {
      return null;
    }
    final result = await _channel.invokeMethod<dynamic>(
      'publishIncomingDownload',
      {
        'stagingPath': stagingPath,
        'fileName': fileName,
        'mediaType': mediaType,
      },
    );
    return result is Map ? result : null;
  }

  static Future<Map<dynamic, dynamic>?> consumeLaunchAction() async {
    if (!isSupported) {
      return null;
    }
    final result = await _channel.invokeMethod<dynamic>('consumeLaunchAction');
    return result is Map ? result : null;
  }

  static Future<String> getNotificationPermissionStatus() async {
    if (!isSupported) {
      return 'unknown';
    }
    final result = await _channel.invokeMethod<String>(
      'getNotificationPermissionStatus',
    );
    return result ?? 'unknown';
  }

  static Future<bool> requestNotificationPermission() async {
    if (!isSupported) {
      return true;
    }
    final result = await _channel.invokeMethod<bool>(
      'requestNotificationPermission',
    );
    return result ?? false;
  }

  static Future<void> showToast(String message) async {
    if (!isSupported) {
      return;
    }
    await _channel.invokeMethod<void>('showToast', {
      'message': message,
    });
  }

  static Future<bool> openNotificationSettings() async {
    if (!isSupported) {
      return false;
    }
    final result =
        await _channel.invokeMethod<bool>('openNotificationSettings');
    return result ?? false;
  }

  static Future<String> getNotificationListenerAccessStatus() async {
    if (!isSupported) {
      return 'unknown';
    }
    final result = await _channel.invokeMethod<String>(
      'getNotificationListenerAccessStatus',
    );
    return result ?? 'unknown';
  }

  static Future<bool> openNotificationListenerSettings() async {
    if (!isSupported) {
      return false;
    }
    final result = await _channel.invokeMethod<bool>(
      'openNotificationListenerSettings',
    );
    return result ?? false;
  }

  static Future<bool> showTestNotification() async {
    if (!isSupported) {
      return false;
    }
    final result = await _channel.invokeMethod<bool>('showTestNotification');
    return result ?? false;
  }

  static Future<bool> showMediaPlayback({
    required Map<String, Object?> playback,
  }) async {
    if (!isSupported) {
      return false;
    }
    final result = await _channel.invokeMethod<bool>('showMediaPlayback', {
      'playback': playback,
    });
    return result ?? false;
  }

  static Future<bool> clearMediaPlayback() async {
    if (!isSupported) {
      return false;
    }
    final result = await _channel.invokeMethod<bool>('clearMediaPlayback');
    return result ?? false;
  }

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
