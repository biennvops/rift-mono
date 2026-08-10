import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsMediaPlayback {
  static const MethodChannel _channel =
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
    if (!isSupported) return false;
    final started = await _channel.invokeMethod<bool>('startObservation');
    return started ?? false;
  }

  static Future<bool> stopObservation() async {
    if (!isSupported) return false;
    final stopped = await _channel.invokeMethod<bool>('stopObservation');
    return stopped ?? false;
  }

  static Future<Map<String, dynamic>?> performAction({
    required String playbackId,
    required String action,
    int? positionMs,
  }) async {
    if (!isSupported) {
      return null;
    }
    final result = await _channel.invokeMethod<Object?>('performAction', {
      'playbackId': playbackId,
      'action': action,
      if (positionMs != null) 'positionMs': positionMs,
    });
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return null;
  }

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
