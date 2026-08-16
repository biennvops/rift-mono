import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/platform/android_shell.dart';

class AndroidRemoteMediaPlaybackCoordinator {
  AndroidRemoteMediaPlaybackCoordinator(
    this._client, {
    Duration successfulActionReconciliationDelay = const Duration(seconds: 2),
  }) : _successfulActionReconciliationDelay =
            successfulActionReconciliationDelay;

  static final RegExp _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static const int _maxEarlyActionResults = 32;

  final JsonRpcRiftClient _client;
  final Duration _successfulActionReconciliationDelay;
  final Map<String, Map<String, dynamic>> _playbacksByKey =
      <String, Map<String, dynamic>>{};
  final Map<String, _PendingRemoteMediaAction> _pendingActionsByOperationId =
      <String, _PendingRemoteMediaAction>{};
  final Map<String, String> _pendingOperationIdsByActionKey =
      <String, String>{};
  final Map<String, String> _latestOperationIdsByPlaybackKey =
      <String, String>{};
  final Map<String, Timer> _reconciliationTimersByPlaybackKey =
      <String, Timer>{};
  final Map<String, int> _playbackRevisions = <String, int>{};
  final Map<String, Map<String, dynamic>> _earlyActionResults =
      <String, Map<String, dynamic>>{};
  final Set<String> _dispatchingActionKeys = <String>{};
  final Set<Future<dynamic>> _activeWork = <Future<dynamic>>{};
  Future<void> _nativeSyncTail = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _disposed = false;
  String? _localDeviceId;

  StreamSubscription<Map<String, dynamic>>? _postedSub;
  StreamSubscription<Map<String, dynamic>>? _updatedSub;
  StreamSubscription<Map<String, dynamic>>? _removedSub;
  StreamSubscription<Map<String, dynamic>>? _actionResultSub;
  StreamSubscription<bool>? _connectionSub;

  Future<void> start() {
    if (_disposed) return Future<void>.value();
    return _trackWork(_start);
  }

  Future<void> _start() async {
    if (_disposed || !AndroidShell.isSupported) {
      return;
    }

    _postedSub = _client.onMediaPlaybackPosted.listen(_upsertPlayback);
    _updatedSub = _client.onMediaPlaybackUpdated.listen(_upsertPlayback);
    _removedSub = _client.onMediaPlaybackRemoved.listen(_removePlayback);
    _actionResultSub = _client.onMediaPlaybackActionResult.listen((result) {
      if (!_disposed) {
        unawaited(_trackWork(() => _handleActionResult(result)));
      }
    });
    _connectionSub = _client.onConnectionChanged.listen((isConnected) {
      if (_disposed) return;
      if (isConnected) {
        unawaited(refresh());
      } else {
        _clearRemoteState();
        unawaited(_queueNativeStateSync().catchError((_) {}));
      }
    });
    await refresh();
  }

  Future<void> dispose() {
    _disposed = true;
    return _disposeFuture ??= _performDispose();
  }

  Future<void> _performDispose() async {
    final subscriptions = <StreamSubscription<dynamic>?>[
      _postedSub,
      _updatedSub,
      _removedSub,
      _actionResultSub,
      _connectionSub,
    ];
    _postedSub = null;
    _updatedSub = null;
    _removedSub = null;
    _actionResultSub = null;
    _connectionSub = null;
    for (final subscription in subscriptions) {
      try {
        await subscription?.cancel();
      } catch (error) {
        debugPrint('[Media Playback] Failed to cancel subscription: $error');
      }
    }
    _clearActionState();
    while (_activeWork.isNotEmpty) {
      final activeWork = List<Future<dynamic>>.of(_activeWork);
      for (final work in activeWork) {
        try {
          await work;
        } catch (_) {}
      }
    }
    try {
      await _nativeSyncTail;
    } catch (_) {}
  }

  Future<dynamic> handlePlatformMethodCall(MethodCall call) {
    if (_disposed) return Future<dynamic>.value(null);
    return _trackWork(() => _handlePlatformMethodCall(call));
  }

  Future<dynamic> _handlePlatformMethodCall(MethodCall call) async {
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

    final playbackKey = _key(sourceDeviceId, playbackId);
    final playback = _playbacksByKey[playbackKey];
    if (playback == null) {
      return false;
    }

    final actionKey = _actionKey(sourceDeviceId, playbackId, action);
    if (_dispatchingActionKeys.contains(actionKey) ||
        _pendingOperationIdsByActionKey.containsKey(actionKey)) {
      debugPrint(
        '[Media Playback] Coalesced pending action '
        'sourceDeviceId=$sourceDeviceId playbackId=$playbackId action=$action',
      );
      return true;
    }
    if (!_isActionApplicable(playback, action)) {
      debugPrint(
        '[Media Playback] Suppressed stale action '
        'sourceDeviceId=$sourceDeviceId playbackId=$playbackId action=$action',
      );
      return true;
    }

    _dispatchingActionKeys.add(actionKey);
    final previousPlayback = Map<String, dynamic>.from(playback);
    try {
      final rawResult = await _client.performMediaPlaybackAction(
        sourceDeviceId: sourceDeviceId,
        playbackId: playbackId,
        action: action,
        positionMs: positionMs,
      );
      if (_disposed) return false;
      if (rawResult is! Map) {
        throw StateError('Playback action response must be an object');
      }
      final result = Map<String, dynamic>.from(rawResult);
      final operationId = result['operationId']?.toString();
      if (operationId == null || !_uuidV4.hasMatch(operationId)) {
        throw StateError('Playback action response has an invalid operationId');
      }
      final resultPlaybackId = result['playbackId']?.toString();
      final resultAction = result['action']?.toString();
      if ((resultPlaybackId != null && resultPlaybackId != playbackId) ||
          (resultAction != null && resultAction != action)) {
        throw StateError('Playback action response identity mismatch');
      }

      _reconciliationTimersByPlaybackKey.remove(playbackKey)?.cancel();
      _latestOperationIdsByPlaybackKey[playbackKey] = operationId;
      if (_isPlayPauseAction(action)) {
        final current = _playbacksByKey[playbackKey];
        if (current != null) {
          final optimistic = Map<String, dynamic>.from(current);
          _applyOptimisticPlayPause(optimistic, action);
          _playbacksByKey[playbackKey] = optimistic;
          _nextRevision(playbackKey);
          unawaited(_queueNativeStateSync().catchError((_) {}));
        }
      }

      final pending = _PendingRemoteMediaAction(
        operationId: operationId,
        sourceDeviceId: sourceDeviceId,
        playbackId: playbackId,
        action: action,
        previousPlayback: previousPlayback,
      );
      _pendingActionsByOperationId[operationId] = pending;
      _pendingOperationIdsByActionKey[actionKey] = operationId;
      debugPrint(
        '[Media Playback] Dispatched action operationId=$operationId '
        'requestingDeviceId=$_localDeviceId sourceDeviceId=$sourceDeviceId '
        'playbackId=$playbackId action=$action',
      );

      final earlyResult = _earlyActionResults.remove(operationId);
      if (earlyResult != null) {
        await _handleActionResult(earlyResult, bufferUnknown: false);
      }
      return true;
    } catch (error) {
      if (!_disposed) {
        debugPrint('[Media Playback] Failed to perform remote action: $error');
        unawaited(refresh());
      }
      return false;
    } finally {
      _dispatchingActionKeys.remove(actionKey);
    }
  }

  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    return _trackWork(_refresh);
  }

  Future<void> _refresh() async {
    if (_disposed || !AndroidShell.isSupported || !_client.isConnected) {
      return;
    }

    try {
      await _ensureLocalDeviceId();
      if (_disposed) return;
      final result = await _client.listMediaPlayback();
      if (_disposed) return;
      final playbacks = List<Map<String, dynamic>>.from(
        (result['playbacks'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      for (final key in _playbacksByKey.keys) {
        _clearPlaybackOwnership(key);
        _nextRevision(key);
      }
      _playbacksByKey
        ..clear()
        ..addEntries(
          playbacks
              .where(_isRemotePlayback)
              .map((playback) => MapEntry(_keyFor(playback), playback)),
        );
      for (final key in _playbacksByKey.keys) {
        _nextRevision(key);
      }
      await _queueNativeStateSync();
    } catch (error) {
      if (!_disposed) {
        debugPrint(
          '[Media Playback] Failed to refresh mirrored playbacks: $error',
        );
      }
    }
  }

  Future<void> _ensureLocalDeviceId() async {
    if (_disposed || _localDeviceId != null) return;
    final info = await _client.getDeviceInfo();
    if (_disposed) return;
    if (info is Map) {
      final deviceId = info['deviceId']?.toString();
      if (deviceId != null && deviceId.isNotEmpty) {
        _localDeviceId = deviceId;
      }
    }
  }

  /// The daemon stores this device's own published sessions too, but
  /// mirroring them locally would show a duplicate player for media that is
  /// already playing on this device.
  bool _isRemotePlayback(Map<String, dynamic> playback) {
    final localDeviceId = _localDeviceId;
    if (localDeviceId == null) return true;
    return playback['sourceDeviceId']?.toString() != localDeviceId;
  }

  void _upsertPlayback(Map<String, dynamic> playback) {
    if (_disposed || !_isRemotePlayback(playback)) {
      return;
    }
    final key = _keyFor(playback);
    // Playback events can be reordered around an action result, so they update
    // displayed state without canceling that operation's bounded reconciliation.
    _playbacksByKey[key] = Map<String, dynamic>.from(playback);
    _nextRevision(key);
    unawaited(_queueNativeStateSync().catchError((_) {}));
  }

  void _removePlayback(Map<String, dynamic> playback) {
    if (_disposed) return;
    final key = _keyFor(playback);
    _clearPlaybackOwnership(key);
    _playbacksByKey.remove(key);
    _nextRevision(key);
    unawaited(_queueNativeStateSync().catchError((_) {}));
  }

  Future<void> _handleActionResult(
    Map<String, dynamic> result, {
    bool bufferUnknown = true,
  }) async {
    if (_disposed) return;
    final operationId = result['operationId']?.toString();
    if (operationId == null || !_uuidV4.hasMatch(operationId)) {
      debugPrint('[Media Playback] Ignored action result without a valid ID');
      return;
    }

    final pending = _pendingActionsByOperationId[operationId];
    if (pending == null) {
      if (bufferUnknown) {
        _earlyActionResults[operationId] = Map<String, dynamic>.from(result);
        while (_earlyActionResults.length > _maxEarlyActionResults) {
          _earlyActionResults.remove(_earlyActionResults.keys.first);
        }
      }
      debugPrint(
        '[Media Playback] Ignored unmatched action result '
        'operationId=$operationId',
      );
      return;
    }

    final sourceDeviceId = result['sourceDeviceId']?.toString();
    final playbackId = result['playbackId']?.toString();
    final action = result['action']?.toString();
    final success = result['success'];
    if (sourceDeviceId != pending.sourceDeviceId ||
        playbackId != pending.playbackId ||
        action != pending.action ||
        success is! bool) {
      debugPrint(
        '[Media Playback] Ignored mismatched action result '
        'operationId=$operationId',
      );
      return;
    }

    _pendingActionsByOperationId.remove(operationId);
    final actionKey = _actionKey(
      pending.sourceDeviceId,
      pending.playbackId,
      pending.action,
    );
    if (_pendingOperationIdsByActionKey[actionKey] == operationId) {
      _pendingOperationIdsByActionKey.remove(actionKey);
    }

    final playbackKey = pending.playbackKey;
    final isLatest =
        _latestOperationIdsByPlaybackKey[playbackKey] == operationId;
    debugPrint(
      '[Media Playback] Received action result operationId=$operationId '
      'requestingDeviceId=$_localDeviceId '
      'sourceDeviceId=${pending.sourceDeviceId} '
      'playbackId=${pending.playbackId} action=${pending.action} '
      'success=$success',
    );
    if (!isLatest) {
      return;
    }

    if (success) {
      _scheduleSuccessfulActionReconciliation(pending);
      return;
    }

    debugPrint(
      '[Media Playback] Reconciling failed action operationId=$operationId '
      'previousState=${pending.previousPlayback['playbackState']}',
    );
    await _refreshPlayback(pending);
  }

  void _scheduleSuccessfulActionReconciliation(
    _PendingRemoteMediaAction pending,
  ) {
    if (_disposed) return;
    final key = pending.playbackKey;
    _reconciliationTimersByPlaybackKey.remove(key)?.cancel();
    _reconciliationTimersByPlaybackKey[key] = Timer(
      _successfulActionReconciliationDelay,
      () {
        if (!_disposed) unawaited(_refreshPlayback(pending));
      },
    );
  }

  Future<void> _refreshPlayback(_PendingRemoteMediaAction pending) {
    if (_disposed) return Future<void>.value();
    return _trackWork(() => _performRefreshPlayback(pending));
  }

  Future<void> _performRefreshPlayback(
    _PendingRemoteMediaAction pending,
  ) async {
    if (_disposed ||
        !_client.isConnected ||
        _latestOperationIdsByPlaybackKey[pending.playbackKey] !=
            pending.operationId) {
      return;
    }

    final expectedRevision = _playbackRevisions[pending.playbackKey] ?? 0;
    try {
      final result = await _client.getMediaPlayback(
        sourceDeviceId: pending.sourceDeviceId,
        playbackId: pending.playbackId,
      );
      if (_disposed ||
          result is! Map ||
          _latestOperationIdsByPlaybackKey[pending.playbackKey] !=
              pending.operationId ||
          (_playbackRevisions[pending.playbackKey] ?? 0) != expectedRevision) {
        return;
      }

      final playback = Map<String, dynamic>.from(result);
      if (playback['sourceDeviceId']?.toString() != pending.sourceDeviceId ||
          playback['playbackId']?.toString() != pending.playbackId ||
          !_isRemotePlayback(playback)) {
        return;
      }
      _clearPlaybackOwnership(pending.playbackKey);
      _playbacksByKey[pending.playbackKey] = playback;
      _nextRevision(pending.playbackKey);
      await _queueNativeStateSync();
    } catch (error) {
      if (!_disposed) {
        debugPrint(
          '[Media Playback] Failed to reconcile operation '
          '${pending.operationId}: $error',
        );
      }
    }
  }

  bool _isActionApplicable(Map<String, dynamic> playback, String action) {
    final state = playback['playbackState']?.toString();
    return switch (action) {
      'play' => state != 'playing' && playback['canPlay'] == true,
      'pause' => state == 'playing' && playback['canPause'] == true,
      'togglePlayPause' =>
        playback['canPlay'] == true || playback['canPause'] == true,
      'next' => playback['canSkipNext'] == true,
      'previous' => playback['canSkipPrevious'] == true,
      'seek' => playback['canSeek'] == true,
      _ => false,
    };
  }

  bool _isPlayPauseAction(String action) =>
      action == 'play' || action == 'pause' || action == 'togglePlayPause';

  void _applyOptimisticPlayPause(
    Map<String, dynamic> playback,
    String action,
  ) {
    final shouldPlay = action == 'play' ||
        (action == 'togglePlayPause' &&
            playback['playbackState']?.toString() != 'playing');
    playback['playbackState'] = shouldPlay ? 'playing' : 'paused';
    playback['canPlay'] = !shouldPlay;
    playback['canPause'] = shouldPlay;
  }

  void _clearPlaybackOwnership(String key) {
    _latestOperationIdsByPlaybackKey.remove(key);
    _reconciliationTimersByPlaybackKey.remove(key)?.cancel();
  }

  void _clearActionState() {
    for (final timer in _reconciliationTimersByPlaybackKey.values) {
      timer.cancel();
    }
    _reconciliationTimersByPlaybackKey.clear();
    _pendingActionsByOperationId.clear();
    _pendingOperationIdsByActionKey.clear();
    _latestOperationIdsByPlaybackKey.clear();
    _earlyActionResults.clear();
    _dispatchingActionKeys.clear();
  }

  void _clearRemoteState() {
    _clearActionState();
    _playbacksByKey.clear();
    _playbackRevisions.clear();
  }

  int _nextRevision(String key) {
    final revision = (_playbackRevisions[key] ?? 0) + 1;
    _playbackRevisions[key] = revision;
    return revision;
  }

  Future<T> _trackWork<T>(Future<T> Function() operation) {
    final future = operation();
    _activeWork.add(future);
    unawaited(
      future.then<void>(
        (_) => _activeWork.remove(future),
        onError: (Object _, StackTrace __) {
          _activeWork.remove(future);
        },
      ),
    );
    return future;
  }

  Future<void> _queueNativeStateSync() {
    if (_disposed) return Future<void>.value();
    late final Future<void> next;
    next = _nativeSyncTail.catchError((_) {}).then<void>((_) async {
      if (!_disposed) await _syncNativeState();
    });
    _nativeSyncTail = next.catchError((_) {});
    return next;
  }

  Future<void> _syncNativeState() async {
    if (_disposed) return;
    final playback = _selectCurrentPlayback();
    if (playback == null) {
      await AndroidShell.clearMediaPlayback();
      return;
    }

    await AndroidShell.showMediaPlayback(playback: <String, Object?>{
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
      if (candidate['playbackState']?.toString() != 'stopped') {
        return candidate;
      }
    }
    return null;
  }

  String _keyFor(Map<String, dynamic> playback) => _key(
        playback['sourceDeviceId']?.toString() ?? '',
        playback['playbackId']?.toString() ?? '',
      );

  String _key(String sourceDeviceId, String playbackId) =>
      '$sourceDeviceId:$playbackId';

  String _actionKey(
    String sourceDeviceId,
    String playbackId,
    String action,
  ) =>
      '$sourceDeviceId\n$playbackId\n$action';
}

class _PendingRemoteMediaAction {
  const _PendingRemoteMediaAction({
    required this.operationId,
    required this.sourceDeviceId,
    required this.playbackId,
    required this.action,
    required this.previousPlayback,
  });

  final String operationId;
  final String sourceDeviceId;
  final String playbackId;
  final String action;
  final Map<String, dynamic> previousPlayback;

  String get playbackKey => '$sourceDeviceId:$playbackId';
}
