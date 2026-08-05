import 'dart:async';

import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/platform/macos_media_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MacOSRemoteMediaPlaybackCoordinator {
  MacOSRemoteMediaPlaybackCoordinator(this._client);

  final JsonRpcRiftClient _client;
  final Map<String, Map<String, dynamic>> _playbacksByKey =
      <String, Map<String, dynamic>>{};
  String? _localDeviceId;

  StreamSubscription<Map<String, dynamic>>? _postedSub;
  StreamSubscription<Map<String, dynamic>>? _updatedSub;
  StreamSubscription<Map<String, dynamic>>? _removedSub;
  StreamSubscription<Map<String, dynamic>>? _actionResultSub;
  StreamSubscription<bool>? _connectionSub;
  Timer? _actionRefreshTimer;

  Future<void> start() async {
    if (!MacOSMediaPlaybackBridge.isSupported) return;

    MacOSMediaPlaybackBridge.setMethodCallHandler(handlePlatformMethodCall);
    _postedSub = _client.onMediaPlaybackPosted.listen(_upsertPlayback);
    _updatedSub = _client.onMediaPlaybackUpdated.listen(_upsertPlayback);
    _removedSub = _client.onMediaPlaybackRemoved.listen(_removePlayback);
    _actionResultSub = _client.onMediaPlaybackActionResult.listen((_) {
      _scheduleAuthoritativeRefresh(Duration.zero);
    });
    _connectionSub = _client.onConnectionChanged.listen((isConnected) {
      if (isConnected) unawaited(refresh());
    });
    await refresh();
  }

  Future<void> dispose() async {
    MacOSMediaPlaybackBridge.setMethodCallHandler(null);
    await _postedSub?.cancel();
    await _updatedSub?.cancel();
    await _removedSub?.cancel();
    await _actionResultSub?.cancel();
    await _connectionSub?.cancel();
    _actionRefreshTimer?.cancel();
    if (MacOSMediaPlaybackBridge.isSupported) {
      await MacOSMediaPlaybackBridge.clearRemotePlayback();
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
      debugPrint('[macOS Media Playback] Failed to perform action: $error');
      return false;
    }
  }

  void _scheduleAuthoritativeRefresh(Duration delay) {
    _actionRefreshTimer?.cancel();
    _actionRefreshTimer = Timer(delay, () => unawaited(refresh()));
  }

  Future<void> refresh() async {
    if (!MacOSMediaPlaybackBridge.isSupported || !_client.isConnected) return;

    try {
      await _ensureLocalDeviceId();
      final result = await _client.listMediaPlayback();
      final playbacks = List<Map<String, dynamic>>.from(
        (result['playbacks'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      _playbacksByKey
        ..clear()
        ..addEntries(
          playbacks
              .where(_isRemotePlayback)
              .map((playback) => MapEntry(_keyFor(playback), playback)),
        );
      await _syncNativeState();
    } catch (error) {
      debugPrint('[macOS Media Playback] Failed to refresh state: $error');
    }
  }

  Future<void> _ensureLocalDeviceId() async {
    if (_localDeviceId != null) return;
    final info = await _client.getDeviceInfo();
    if (info is Map) {
      final deviceId = info['deviceId']?.toString();
      if (deviceId != null && deviceId.isNotEmpty) {
        _localDeviceId = deviceId;
      }
    }
  }

  bool _isRemotePlayback(Map<String, dynamic> playback) {
    final localDeviceId = _localDeviceId;
    if (localDeviceId == null) return true;
    return playback['sourceDeviceId']?.toString() != localDeviceId;
  }

  void _upsertPlayback(Map<String, dynamic> playback) {
    if (!_isRemotePlayback(playback)) return;
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
      await MacOSMediaPlaybackBridge.clearRemotePlayback();
      return;
    }

    await MacOSMediaPlaybackBridge.showRemotePlayback(
      playback: <String, Object?>{
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
      },
    );
  }

  Map<String, dynamic>? _selectCurrentPlayback() {
    if (_playbacksByKey.isEmpty) return null;

    final candidates = _playbacksByKey.values.toList(growable: false)
      ..sort((a, b) {
        final left = DateTime.tryParse(
          a['updatedAt']?.toString() ?? '',
        )?.toUtc();
        final right = DateTime.tryParse(
          b['updatedAt']?.toString() ?? '',
        )?.toUtc();
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
