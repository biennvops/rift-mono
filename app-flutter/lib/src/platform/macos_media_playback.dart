import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MacOSMediaPlaybackBridge {
  static const MethodChannel _methodChannel =
      MethodChannel('rift/macos/media_playback');
  static const EventChannel _eventChannel =
      EventChannel('rift/macos/media_playback_events');
  @visibleForTesting
  static bool? debugIsMacOSOverride;

  static bool get isSupported => debugIsMacOSOverride ?? Platform.isMacOS;

  static Stream<Map<String, dynamic>> get events {
    if (!isSupported) {
      return const Stream<Map<String, dynamic>>.empty();
    }
    return _eventChannel.receiveBroadcastStream().map((event) {
      return Map<String, dynamic>.from(event as Map);
    });
  }

  static Future<bool> startObservation() async {
    if (!isSupported) {
      return false;
    }
    final result = await _methodChannel.invokeMethod<bool>('startObservation');
    return result ?? false;
  }

  static Future<bool> stopObservation() async {
    if (!isSupported) {
      return false;
    }
    final result = await _methodChannel.invokeMethod<bool>('stopObservation');
    return result ?? false;
  }

  static Future<bool> showRemotePlayback({
    required Map<String, Object?> playback,
  }) async {
    if (!isSupported) return false;
    final shown = await _methodChannel.invokeMethod<bool>('showRemotePlayback', {
      'playback': playback,
    });
    return shown ?? false;
  }

  static Future<bool> clearRemotePlayback() async {
    if (!isSupported) return false;
    final cleared =
        await _methodChannel.invokeMethod<bool>('clearRemotePlayback');
    return cleared ?? false;
  }

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _methodChannel.setMethodCallHandler(handler);
  }

  static Future<Map<String, dynamic>?> performAction({
    required String action,
    int? positionMs,
  }) async {
    if (!isSupported) {
      return null;
    }
    final result = await _methodChannel.invokeMethod<Object?>('performAction', {
      'action': action,
      if (positionMs != null) 'positionMs': positionMs,
    });
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return null;
  }
}
