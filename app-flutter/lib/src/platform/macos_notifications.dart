import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class DesktopNotificationAction {
  const DesktopNotificationAction({
    required this.id,
    required this.title,
  });

  final String id;
  final String title;

  Map<String, String> toMap() => <String, String>{
        'id': id,
        'title': title,
      };
}

class MacOSNotifications {
  static const MethodChannel _channel = MethodChannel('rift.permissions');
  @visibleForTesting
  static bool? debugIsMacOSOverride;

  static bool get _isMacOS => debugIsMacOSOverride ?? Platform.isMacOS;

  static bool get isSupported => _isMacOS || Platform.isAndroid;
  static bool get supportsPendingShareHandoff => _isMacOS;

  static Future<String> getStatus() async {
    if (!_isMacOS) return 'unknown';
    final res = await _channel.invokeMethod<String>('notification.getStatus');
    return res ?? 'unknown';
  }

  static Future<bool> request() async {
    if (!_isMacOS) return true;
    final res = await _channel.invokeMethod<bool>('notification.request');
    return res ?? false;
  }

  static Future<bool> show({
    required String title,
    required String body,
    String? route,
    Map<String, Object?>? payload,
    List<DesktopNotificationAction>? actions,
  }) async {
    if (!_isMacOS) return true;
    final res = await _channel.invokeMethod<bool>('notification.show', {
      'title': title,
      'body': body,
      if (route != null) 'route': route,
      if (payload != null) 'payload': payload,
      if (actions != null)
        'actions': actions.map((action) => action.toMap()).toList(),
    });
    return res ?? false;
  }

  static Future<Map<String, dynamic>?> consumePendingShareItems() async {
    if (!_isMacOS) return null;
    final res = await _channel.invokeMethod<Object>('share.consumePendingItems');
    if (res is Map) {
      return Map<String, dynamic>.from(res);
    }
    return null;
  }

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
