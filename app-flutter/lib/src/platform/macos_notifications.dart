import 'dart:io';

import 'package:flutter/services.dart';

class MacOSNotifications {
  static const MethodChannel _channel = MethodChannel('rift.permissions');

  static bool get isSupported => Platform.isMacOS;

  static Future<String> getStatus() async {
    if (!isSupported) return 'unknown';
    final res = await _channel.invokeMethod<String>('notification.getStatus');
    return res ?? 'unknown';
  }

  static Future<bool> request() async {
    if (!isSupported) return true;
    final res = await _channel.invokeMethod<bool>('notification.request');
    return res ?? false;
  }

  static Future<bool> show({
    required String title,
    required String body,
  }) async {
    if (!isSupported) return true;
    final res = await _channel.invokeMethod<bool>('notification.show', {
      'title': title,
      'body': body,
    });
    return res ?? false;
  }
}
