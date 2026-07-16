import 'dart:io';

import 'package:flutter/services.dart';

class LinuxNotifications {
  static const MethodChannel _channel =
      MethodChannel('rift/linux/notifications');

  static bool get isSupported => Platform.isLinux;

  static Future<bool> show({
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

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
