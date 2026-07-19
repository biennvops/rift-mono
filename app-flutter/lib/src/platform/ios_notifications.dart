import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IOSNotifications {
  static const MethodChannel _channel = MethodChannel('rift/ios/notifications');

  @visibleForTesting
  static bool? debugIsIOSOverride;

  static bool get isSupported => debugIsIOSOverride ?? Platform.isIOS;

  static Future<String> getPermissionStatus() async {
    if (!isSupported) return 'unknown';
    final status = await _channel.invokeMethod<String>('getPermissionStatus');
    return status ?? 'unknown';
  }

  static Future<bool> requestPermission() async {
    if (!isSupported) return false;
    final granted = await _channel.invokeMethod<bool>('requestPermission');
    return granted ?? false;
  }

  static Future<bool> show({
    required String title,
    required String body,
    String? route,
    String? destinationPath,
    Map<String, Object?>? payload,
  }) async {
    if (!isSupported) return false;
    final shown = await _channel.invokeMethod<bool>('showNotification', {
      'title': title,
      'body': body,
      if (route != null) 'route': route,
      if (destinationPath != null) 'destinationPath': destinationPath,
      if (payload != null) 'payload': payload,
    });
    return shown ?? false;
  }

  static Future<bool> openSettings() async {
    if (!isSupported) return false;
    final opened = await _channel.invokeMethod<bool>('openSettings');
    return opened ?? false;
  }

  static Future<Map<String, dynamic>?> consumeLaunchAction() async {
    if (!isSupported) return null;
    final action = await _channel.invokeMethod<Object>('consumeLaunchAction');
    if (action is Map) {
      return Map<String, dynamic>.from(action);
    }
    return null;
  }

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
