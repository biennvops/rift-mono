import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rift/src/platform/macos_notifications.dart';

class LinuxNotifications {
  static const MethodChannel _channel =
      MethodChannel('rift/linux/notifications');
  @visibleForTesting
  static bool? debugIsLinuxOverride;

  static bool get isSupported => debugIsLinuxOverride ?? Platform.isLinux;

  static Future<bool> show({
    required String title,
    required String body,
    required String route,
    String? destinationPath,
    Map<String, Object?>? payload,
    List<DesktopNotificationAction>? actions,
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
      if (actions != null)
        'actions': actions.map((action) => action.toMap()).toList(),
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

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
