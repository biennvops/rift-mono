import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/platform/windows_media_playback.dart';

class WindowsRemoteMediaPlaybackCoordinator {
  WindowsRemoteMediaPlaybackCoordinator(this._client);

  final JsonRpcRiftClient _client;
  final Map<String, Map<String, dynamic>> _playbacksByKey =
      <String, Map<String, dynamic>>{};

  StreamSubscription<Map<String, dynamic>>? _postedSub;
  StreamSubscription<Map<String, dynamic>>? _updatedSub;
  StreamSubscription<Map<String, dynamic>>? _removedSub;
  StreamSubscription<Map<String, dynamic>>? _actionResultSub;
  StreamSubscription<bool>? _connectionSub;
  Timer? _actionRefreshTimer;

  Future<void> start() async {
    if (!WindowsMediaPlayback.isSupported) return;

    WindowsMediaPlayback.setMethodCallHandler(handlePlatformMethodCall);
    _postedSub = _client.onMediaPlaybackPosted.listen(_upsertPlayback);
    _updatedSub = _client.onMediaPlaybackUpdated.listen(_upsertPlayback);
    _removedSub = _client.onMediaPlaybackRemoved.listen(_removePlayback);
    _actionResultSub = _client.onMediaPlaybackActionResult.listen((_) {
      _scheduleAuthoritativeRefresh(Duration.zero);
    });
    _connectionSub = _client.onConnectionChanged.listen((isConnected) {
      if (isConnected) {
        unawaited(refresh());
      } else {
        _actionRefreshTimer?.cancel();
        _playbacksByKey.clear();
        unawaited(WindowsMediaPlayback.clear());
      }
    });
    await refresh();
  }

  Future<void> dispose() async {
    WindowsMediaPlayback.setMethodCallHandler(null);
    await _postedSub?.cancel();
    await _updatedSub?.cancel();
    await _removedSub?.cancel();
    await _actionResultSub?.cancel();
    await _connectionSub?.cancel();
    _actionRefreshTimer?.cancel();
    if (WindowsMediaPlayback.isSupported) {
      await WindowsMediaPlayback.clear();
    }
  }

  Future<dynamic> handlePlatformMethodCall(MethodCall call) async {
    if (call.method != 'mediaPlaybackAction' || call.arguments is! Map) {
      return null;
    }

    final payload = Map<String, dynamic>.from(call.arguments as Map);
    final sourceDeviceId = payload['sourceDeviceId']?.toString();
    final playbackId = payload['playbackId']?.toString();
    final action = payload['action']?.toString();
    final positionMs = (payload['positionMs'] as num?)?.toInt();
    if (sourceDeviceId == null ||
        sourceDeviceId.isEmpty ||
        playbackId == null ||
        playbackId.isEmpty ||
        action == null ||
        action.isEmpty) {
      return false;
    }

    try {
      await _client.performMediaPlaybackAction(
        sourceDeviceId: sourceDeviceId,
        playbackId: playbackId,
        action: action,
        positionMs: positionMs,
      );
      _scheduleAuthoritativeRefresh(const Duration(milliseconds: 300));
      return true;
    } catch (error) {
      debugPrint('[Windows Media Playback] Failed to perform action: $error');
      return false;
    }
  }

  void _scheduleAuthoritativeRefresh(Duration delay) {
    _actionRefreshTimer?.cancel();
    _actionRefreshTimer = Timer(delay, () => unawaited(refresh()));
  }

  Future<void> refresh() async {
    if (!WindowsMediaPlayback.isSupported || !_client.isConnected) return;

    try {
      final result = await _client.listMediaPlayback();
      final playbacks = List<Map<String, dynamic>>.from(
        (result['playbacks'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      _playbacksByKey
        ..clear()
        ..addEntries(
          playbacks.map((playback) => MapEntry(_keyFor(playback), playback)),
        );
      await _syncNativeState();
    } catch (error) {
      debugPrint('[Windows Media Playback] Failed to refresh state: $error');
    }
  }

  void _upsertPlayback(Map<String, dynamic> playback) {
    _playbacksByKey[_keyFor(playback)] = Map<String, dynamic>.from(playback);
    unawaited(_syncNativeState());
  }

  void _removePlayback(Map<String, dynamic> playback) {
    _playbacksByKey.remove(_keyFor(playback));
    unawaited(_syncNativeState());
  }

  Future<void> _syncNativeState() async {
    final playback = _selectCurrentPlayback();
    if (playback == null) {
      await WindowsMediaPlayback.clear();
      return;
    }

    await WindowsMediaPlayback.show(playback: <String, Object?>{
      'playbackId': playback['playbackId']?.toString(),
      'sourceDeviceId': playback['sourceDeviceId']?.toString(),
      'sourcePlatform': playback['sourcePlatform']?.toString(),
      'appId': playback['appId']?.toString(),
      'appName': playback['appName']?.toString(),
      'title': playback['title']?.toString(),
      'artist': playback['artist']?.toString(),
      'album': playback['album']?.toString(),
      'artwork': playback['artwork'] is Map
          ? Map<String, Object?>.from(playback['artwork'] as Map)
          : null,
      'playbackState': playback['playbackState']?.toString(),
      'positionMs': (playback['positionMs'] as num?)?.toInt() ?? 0,
      'durationMs': (playback['durationMs'] as num?)?.toInt(),
      'canPlay': playback['canPlay'] == true,
      'canPause': playback['canPause'] == true,
      'canSkipNext': playback['canSkipNext'] == true,
      'canSkipPrevious': playback['canSkipPrevious'] == true,
      'canSeek': playback['canSeek'] == true,
      'updatedAt': playback['updatedAt']?.toString(),
    });
  }

  Map<String, dynamic>? _selectCurrentPlayback() {
    if (_playbacksByKey.isEmpty) return null;

    final candidates = _playbacksByKey.values.toList(growable: false)
      ..sort((a, b) {
        final left =
            DateTime.tryParse(a['updatedAt']?.toString() ?? '')?.toUtc();
        final right =
            DateTime.tryParse(b['updatedAt']?.toString() ?? '')?.toUtc();
        if (left == null && right == null) return 0;
        if (left == null) return 1;
        if (right == null) return -1;
        return right.compareTo(left);
      });

    for (final candidate in candidates) {
      if (candidate['playbackState']?.toString() != 'stopped') {
        return candidate;
      }
    }
    return null;
  }

  String _keyFor(Map<String, dynamic> playback) =>
      '${playback['sourceDeviceId']}:${playback['playbackId']}';
}
