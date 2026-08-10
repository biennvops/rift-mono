import 'dart:async';

import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/platform/android_media_playback.dart';
import 'package:flutter/foundation.dart';

/// Publishes local Android media sessions to the daemon so trusted peers can
/// display and control them. Counterpart to [MacOSMediaPlaybackPublisher].
class AndroidMediaPlaybackPublisher {
  AndroidMediaPlaybackPublisher(this._client);

  final JsonRpcRiftClient _client;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<Map<String, dynamic>>? _actionRequestSub;
  StreamSubscription<bool>? _connectionSub;

  Future<void> start() async {
    if (!AndroidMediaPlaybackBridge.isSupported) {
      return;
    }

    _eventSub = AndroidMediaPlaybackBridge.events.listen(_handlePlaybackEvent);
    _actionRequestSub = _client.onMediaPlaybackActionRequest.listen(
      _handleActionRequest,
    );
    // Observation start is best-effort: it fails silently until the user
    // grants notification listener access, so retry on every reconnect.
    _connectionSub = _client.onConnectionChanged.listen((isConnected) {
      if (isConnected) {
        unawaited(AndroidMediaPlaybackBridge.startObservation());
      }
    });
    await AndroidMediaPlaybackBridge.startObservation();
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _actionRequestSub?.cancel();
    await _connectionSub?.cancel();
    await AndroidMediaPlaybackBridge.stopObservation();
  }

  Future<void> _handlePlaybackEvent(Map<String, dynamic> event) async {
    final eventType = event['eventType']?.toString();
    final playbackId = event['playbackId']?.toString();
    if (eventType == null ||
        eventType.isEmpty ||
        playbackId == null ||
        playbackId.isEmpty ||
        !_client.isConnected) {
      return;
    }

    final payload = <String, Object?>{
      'playbackId': playbackId,
      if (event['sourcePlatform'] != null)
        'sourcePlatform': event['sourcePlatform']?.toString(),
      if (event['appId'] != null) 'appId': event['appId']?.toString(),
      if (event['appName'] != null) 'appName': event['appName']?.toString(),
      if (event['title'] != null) 'title': event['title']?.toString(),
      if (event['artist'] != null) 'artist': event['artist']?.toString(),
      if (event['album'] != null) 'album': event['album']?.toString(),
      if (event['artwork'] is Map)
        'artwork': Map<String, dynamic>.from(event['artwork'] as Map),
      if (event['playbackState'] != null)
        'playbackState': event['playbackState']?.toString(),
      if (event['positionMs'] is num)
        'positionMs': (event['positionMs'] as num).toInt(),
      if (event['durationMs'] is num)
        'durationMs': (event['durationMs'] as num).toInt(),
      'canPlay': event['canPlay'] == true,
      'canPause': event['canPause'] == true,
      'canSkipNext': event['canSkipNext'] == true,
      'canSkipPrevious': event['canSkipPrevious'] == true,
      'canSeek': event['canSeek'] == true,
      if (event['updatedAt'] != null)
        'updatedAt': event['updatedAt']?.toString(),
      if (event['removedAt'] != null)
        'removedAt': event['removedAt']?.toString(),
    };

    try {
      await _client.notifyLocalMediaPlaybackEvent(
        eventType: eventType,
        payload: payload,
      );
    } catch (error) {
      debugPrint(
        '[Media Playback] Failed to publish Android playback event: $error',
      );
    }
  }

  Future<void> _handleActionRequest(Map<String, dynamic> request) async {
    final requestId = request['requestId']?.toString();
    final playbackId = request['playbackId']?.toString();
    final action = request['action']?.toString();
    if (requestId == null ||
        requestId.isEmpty ||
        playbackId == null ||
        playbackId.isEmpty ||
        action == null ||
        action.isEmpty) {
      return;
    }

    final positionMs = (request['positionMs'] as num?)?.toInt();
    var success = false;
    String? failureReason;
    String? message;
    try {
      final result = await AndroidMediaPlaybackBridge.performAction(
        playbackId: playbackId,
        action: action,
        positionMs: positionMs,
      );
      success = result?['success'] == true;
      failureReason = result?['failureReason']?.toString();
      message = result?['message']?.toString();
      if (result == null) {
        failureReason = 'CapabilityUnavailable';
        message = 'The Android playback bridge is unavailable.';
      }
    } catch (error) {
      failureReason = 'PeerRejected';
      message = error.toString();
    }

    try {
      await _client.reportLocalMediaPlaybackActionHandled(
        requestId: requestId,
        success: success,
        failureReason: failureReason,
        message: message,
      );
    } catch (error) {
      debugPrint('[Media Playback] Failed to report handled action: $error');
    }
  }
}
