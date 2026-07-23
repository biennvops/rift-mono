import 'dart:async';
import 'dart:io';

import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/platform/windows_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  Timer? _refreshTimer;
  final Set<String> _pendingActionKeys = <String>{};
  String? _activePlaybackKey;
  String? _lastNotificationSignature;
  String? _localDeviceId;

  Future<void> start() async {
    if (!WindowsShell.isSupported) {
      return;
    }

    _postedSub = _client.onMediaPlaybackPosted.listen(_upsertPlayback);
    _updatedSub = _client.onMediaPlaybackUpdated.listen(_upsertPlayback);
    _removedSub = _client.onMediaPlaybackRemoved.listen(_removePlayback);
    _actionResultSub =
        _client.onMediaPlaybackActionResult.listen(_handleActionResult);
    _connectionSub = _client.onConnectionChanged.listen((isConnected) {
      if (isConnected) {
        unawaited(refresh());
      }
    });

    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(refresh()),
      );
    }

    if (_client.isConnected) {
      await refresh();
    }
  }

  Future<void> dispose() async {
    await _postedSub?.cancel();
    await _updatedSub?.cancel();
    await _removedSub?.cancel();
    await _actionResultSub?.cancel();
    await _connectionSub?.cancel();
    _refreshTimer?.cancel();
    _pendingActionKeys.clear();
    await WindowsShell.clearMediaPlayback();
  }

  Future<dynamic> handlePlatformMethodCall(MethodCall call) async {
    if (call.method != 'mediaPlaybackAction') {
      return null;
    }

    final args = call.arguments;
    if (args is! Map) {
      return null;
    }

    final payload = Map<String, dynamic>.from(args);
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
      return null;
    }

    final pendingKey = _actionKey(sourceDeviceId, playbackId, action);
    if (!_pendingActionKeys.add(pendingKey)) {
      debugPrint(
        '[Media Playback][Windows Remote] ignored duplicate pending action $action for $sourceDeviceId:$playbackId',
      );
      return false;
    }

    try {
      debugPrint(
        '[Media Playback][Windows Remote] action $action for $sourceDeviceId:$playbackId position=$positionMs',
      );
      await _client.performMediaPlaybackAction(
        sourceDeviceId: sourceDeviceId,
        playbackId: playbackId,
        action: action,
        positionMs: positionMs,
      );
      Timer(const Duration(seconds: 35), () {
        _pendingActionKeys.remove(pendingKey);
      });
      return true;
    } catch (error) {
      _pendingActionKeys.remove(pendingKey);
      debugPrint('[Media Playback] Failed to perform remote action: $error');
      return false;
    }
  }

  void _handleActionResult(Map<String, dynamic> result) {
    final sourceDeviceId = result['sourceDeviceId']?.toString();
    final playbackId = result['playbackId']?.toString();
    final action = result['action']?.toString();
    if (sourceDeviceId == null ||
        playbackId == null ||
        action == null) {
      return;
    }

    _pendingActionKeys.remove(_actionKey(sourceDeviceId, playbackId, action));
    debugPrint(
      '[Media Playback][Windows Remote] action result $action state=${result['state']} success=${result['success']}',
    );
  }

  Future<void> refresh() async {
    if (!WindowsShell.isSupported || !_client.isConnected) {
      return;
    }

    try {
      await _ensureLocalDeviceId();
      final result = await _client.listMediaPlayback();
      final playbacks = List<Map<String, dynamic>>.from(
        (result['playbacks'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      final latestBySource = <String, Map<String, dynamic>>{};
      for (final playback in playbacks.where(_isRemotePlayback)) {
        final sourceDeviceId = playback['sourceDeviceId']?.toString();
        if (sourceDeviceId == null || sourceDeviceId.isEmpty) {
          continue;
        }

        final existing = latestBySource[sourceDeviceId];
        if (existing == null || _isNewer(playback, existing)) {
          latestBySource[sourceDeviceId] = playback;
        }
      }
      _playbacksByKey
        ..clear()
        ..addEntries(
          latestBySource.values.map(
            (playback) => MapEntry(_keyFor(playback), playback),
          ),
        );
      await _syncNotificationState();
    } catch (error) {
      debugPrint(
        '[Media Playback] Failed to refresh mirrored playbacks on Windows: $error',
      );
    }
  }

  void _upsertPlayback(Map<String, dynamic> playback) {
    debugPrint('[Media Playback][Windows Remote] upsert $playback');
    if (!_isRemotePlayback(playback)) {
      debugPrint(
        '[Media Playback][Windows Remote] ignored local playback ${playback['sourceDeviceId']}:${playback['playbackId']}',
      );
      _playbacksByKey.remove(_keyFor(playback));
      unawaited(_syncNotificationState());
      return;
    }

    final normalizedPlayback = Map<String, dynamic>.from(playback);
    final sourceDeviceId = normalizedPlayback['sourceDeviceId']?.toString();
    final playbackId = normalizedPlayback['playbackId']?.toString();
    if (sourceDeviceId != null &&
        sourceDeviceId.isNotEmpty &&
        playbackId != null &&
        playbackId.isNotEmpty) {
      _playbacksByKey.removeWhere(
        (key, value) =>
            value['sourceDeviceId']?.toString() == sourceDeviceId &&
            value['playbackId']?.toString() != playbackId,
      );
    }

    _playbacksByKey[_keyFor(normalizedPlayback)] = normalizedPlayback;
    unawaited(_syncNotificationState());
  }

  void _removePlayback(Map<String, dynamic> playback) {
    debugPrint('[Media Playback][Windows Remote] remove $playback');
    _playbacksByKey.remove(_keyFor(playback));
    unawaited(_syncNotificationState());
  }

  Future<void> _syncNotificationState() async {
    final playback = _selectCurrentPlayback();
    if (playback == null) {
      debugPrint('[Media Playback][Windows Remote] no active remote playback');
      _activePlaybackKey = null;
      _lastNotificationSignature = null;
      await WindowsShell.clearMediaPlayback();
      return;
    }

    final playbackKey = _keyFor(playback);
    final signature = _notificationSignature(playback);
    if (_activePlaybackKey == playbackKey &&
        _lastNotificationSignature == signature) {
      return;
    }

    _activePlaybackKey = playbackKey;
    _lastNotificationSignature = signature;

    debugPrint(
      '[Media Playback][Windows Remote] showing ${playback['sourceDeviceId']}:${playback['playbackId']} ${playback['title'] ?? playback['appName'] ?? 'unknown'}',
    );

    try {
      await WindowsShell.showMediaPlayback(playback: <String, Object?>{
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
    } catch (error) {
      debugPrint(
        '[Media Playback] Failed to show Windows playback UI: $error',
      );
    }
  }

  Map<String, dynamic>? _selectCurrentPlayback() {
    final activePlayback = _activePlaybackKey == null
        ? null
        : _playbacksByKey[_activePlaybackKey!];
    if (activePlayback != null && !_isStopped(activePlayback)) {
      return activePlayback;
    }

    if (_playbacksByKey.isEmpty) {
      return null;
    }

    final candidates = _playbacksByKey.values.toList(growable: false)
      ..sort((a, b) {
        final left =
            DateTime.tryParse(a['updatedAt']?.toString() ?? '')?.toUtc();
        final right =
            DateTime.tryParse(b['updatedAt']?.toString() ?? '')?.toUtc();
        if (left == null && right == null) {
          return 0;
        }
        if (left == null) {
          return 1;
        }
        if (right == null) {
          return -1;
        }
        return right.compareTo(left);
      });

    for (final candidate in candidates) {
      if (!_isStopped(candidate)) {
        return candidate;
      }
    }
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<void> _ensureLocalDeviceId() async {
    if (_localDeviceId != null && _localDeviceId!.isNotEmpty) {
      return;
    }

    final deviceInfo = await _client.getDeviceInfo();
    _localDeviceId = deviceInfo['deviceId']?.toString();
  }

  bool _isRemotePlayback(Map<String, dynamic> playback) {
    final sourceDeviceId = playback['sourceDeviceId']?.toString();
    if (sourceDeviceId == null || sourceDeviceId.isEmpty) {
      return false;
    }
    if (_localDeviceId == null || _localDeviceId!.isEmpty) {
      return true;
    }
    return sourceDeviceId != _localDeviceId;
  }

  static bool _isNewer(
    Map<String, dynamic> candidate,
    Map<String, dynamic> existing,
  ) {
    final candidateUpdated =
        DateTime.tryParse(candidate['updatedAt']?.toString() ?? '')?.toUtc();
    final existingUpdated =
        DateTime.tryParse(existing['updatedAt']?.toString() ?? '')?.toUtc();
    if (candidateUpdated == null) {
      return false;
    }
    return existingUpdated == null || candidateUpdated.isAfter(existingUpdated);
  }

  static bool _isStopped(Map<String, dynamic> playback) =>
      playback['playbackState']?.toString() == 'stopped';

  static String _notificationSignature(Map<String, dynamic> playback) => [
        playback['sourceDeviceId']?.toString() ?? '',
        playback['playbackId']?.toString() ?? '',
        playback['title']?.toString() ?? '',
        playback['artist']?.toString() ?? '',
        playback['appName']?.toString() ?? '',
        playback['playbackState']?.toString() ?? '',
        playback['artwork']?.toString() ?? '',
      ].join('\n');

  static String _actionKey(
    String sourceDeviceId,
    String playbackId,
    String action,
  ) =>
      '$sourceDeviceId\n$playbackId\n$action';

  static String _keyFor(Map<String, dynamic> playback) =>
      '${playback['sourceDeviceId']}:${playback['playbackId']}';
}
