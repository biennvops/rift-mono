import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsShell {
  static const MethodChannel _channel = MethodChannel('rift/windows/shell');
  @visibleForTesting
  static bool? debugIsWindowsOverride;

  static bool get isSupported => debugIsWindowsOverride ?? Platform.isWindows;

  static Future<bool> showTransferNotification({
    required String title,
    required String body,
    required String destinationPath,
  }) async {
    if (!isSupported) {
      return false;
    }
    final res = await _channel.invokeMethod<bool>('showTransferNotification', {
      'title': title,
      'body': body,
      'destinationPath': destinationPath,
    });
    return res ?? false;
  }

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
    final res = await _channel.invokeMethod<bool>('showNotification', {
      'title': title,
      'body': body,
      'route': route,
      if (destinationPath != null) 'destinationPath': destinationPath,
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
