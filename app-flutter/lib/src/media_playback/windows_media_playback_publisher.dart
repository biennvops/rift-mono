import 'dart:async';

import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/platform/windows_media_playback.dart';
import 'package:flutter/foundation.dart';

class WindowsMediaPlaybackPublisher {
  WindowsMediaPlaybackPublisher(this._client);

  final JsonRpcRiftClient _client;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<Map<String, dynamic>>? _actionRequestSub;

  Future<void> start() async {
    if (!WindowsMediaPlaybackBridge.isSupported) {
      return;
    }

    try {
      _eventSub = WindowsMediaPlaybackBridge.events.listen(_handlePlaybackEvent);
      _actionRequestSub = _client.onMediaPlaybackActionRequest.listen(
        _handleActionRequest,
      );
      await WindowsMediaPlaybackBridge.startObservation();
    } catch (error) {
      debugPrint(
        '[Media Playback] Windows local playback publishing is unavailable: $error',
      );
    }
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _actionRequestSub?.cancel();
    await WindowsMediaPlaybackBridge.stopObservation();
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
      if (event['updatedAt'] != null) 'updatedAt': event['updatedAt']?.toString(),
      if (event['removedAt'] != null) 'removedAt': event['removedAt']?.toString(),
    };

    try {
      await _client.notifyLocalMediaPlaybackEvent(
        eventType: eventType,
        payload: payload,
      );
    } catch (error) {
      debugPrint('[Media Playback] Failed to publish Windows playback event: $error');
    }
  }

  Future<void> _handleActionRequest(Map<String, dynamic> request) async {
    final requestId = request['requestId']?.toString();
    final action = request['action']?.toString();
    if (requestId == null || requestId.isEmpty || action == null || action.isEmpty) {
      return;
    }

    final positionMs = (request['positionMs'] as num?)?.toInt();
    var success = false;
    String? failureReason;
    String? message;
    try {
      final result = await WindowsMediaPlaybackBridge.performAction(
        action: action,
        positionMs: positionMs,
      );
      success = result?['success'] == true;
      failureReason = result?['failureReason']?.toString();
      message = result?['message']?.toString();
      if (result == null) {
        failureReason = 'CapabilityUnavailable';
        message = 'The Windows playback bridge is unavailable.';
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
