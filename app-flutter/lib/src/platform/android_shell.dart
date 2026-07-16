import 'dart:io';

import 'package:flutter/services.dart';

class AndroidShell {
  static const MethodChannel _channel = MethodChannel('rift/android/shell');

  static bool get isSupported => Platform.isAndroid;

  static Future<bool> showNotification({
    required String title,
    required String body,
    required String route,
    String? destinationPath,
    Map<String, Object?>? payload,
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
    });
    return result ?? false;
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
    final result = await _channel.invokeMethod<bool>('openNotificationSettings');
    return result ?? false;
  }

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
