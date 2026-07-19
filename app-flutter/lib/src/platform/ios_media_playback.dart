import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IOSMediaPlayback {
  static const MethodChannel _channel =
      MethodChannel('rift/ios/media_playback');

  @visibleForTesting
  static bool? debugIsIOSOverride;

  static bool get isSupported => debugIsIOSOverride ?? Platform.isIOS;

  static Future<bool> show({
    required Map<String, Object?> playback,
  }) async {
    if (!isSupported) return false;
    final shown = await _channel.invokeMethod<bool>('show', {
      'playback': playback,
    });
    return shown ?? false;
  }

  static Future<bool> clear() async {
    if (!isSupported) return false;
    final cleared = await _channel.invokeMethod<bool>('clear');
    return cleared ?? false;
  }

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }
}
