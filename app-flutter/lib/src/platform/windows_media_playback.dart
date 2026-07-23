import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsMediaPlaybackBridge {
  static const MethodChannel _methodChannel =
      MethodChannel('rift/windows/media_playback');
  static const EventChannel _eventChannel =
      EventChannel('rift/windows/media_playback_events');
  @visibleForTesting
  static bool? debugIsWindowsOverride;

  static bool get isSupported => debugIsWindowsOverride ?? Platform.isWindows;

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
