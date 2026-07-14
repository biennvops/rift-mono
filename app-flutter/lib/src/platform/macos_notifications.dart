import 'dart:io';

import 'package:flutter/services.dart';

class MacOSNotifications {
  static const MethodChannel _channel = MethodChannel('rift.permissions');

  static bool get isSupported => Platform.isMacOS || Platform.isAndroid;

  static Future<String> getStatus() async {
    if (!Platform.isMacOS) return 'unknown';
    final res = await _channel.invokeMethod<String>('notification.getStatus');
    return res ?? 'unknown';
  }

  static Future<bool> request() async {
    if (!Platform.isMacOS) return true;
    final res = await _channel.invokeMethod<bool>('notification.request');
    return res ?? false;
  }

  static Future<bool> show({
    required String title,
    required String body,
    String? route,
    Map<String, Object?>? payload,
  }) async {
    if (!Platform.isMacOS) return true;
    final res = await _channel.invokeMethod<bool>('notification.show', {
      'title': title,
      'body': body,
      if (route != null) 'route': route,
      if (payload != null) 'payload': payload,
    });
    return res ?? false;
  }

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
