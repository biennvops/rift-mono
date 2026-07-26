import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to the Android media-session observer.
///
/// Observation requires notification listener access (same permission as
/// notification sync); `startObservation` returns false when it is missing.
class AndroidMediaPlaybackBridge {
  static const MethodChannel _methodChannel =
      MethodChannel('rift/android/media_playback');
  static const EventChannel _eventChannel =
      EventChannel('rift/android/media_playback_events');
  @visibleForTesting
  static bool? debugIsAndroidOverride;

  static bool get isSupported => debugIsAndroidOverride ?? Platform.isAndroid;

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
    required String playbackId,
    required String action,
    int? positionMs,
  }) async {
    if (!isSupported) {
      return null;
    }
    final result = await _methodChannel.invokeMethod<Object?>('performAction', {
      'playbackId': playbackId,
      'action': action,
      if (positionMs != null) 'positionMs': positionMs,
    });
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return null;
  }
}
