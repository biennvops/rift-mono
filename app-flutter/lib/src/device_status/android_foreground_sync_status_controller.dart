import 'dart:async';

enum AndroidForegroundSyncRuntimeState {
  starting,
  ready,
  reconnecting,
}

class AndroidForegroundSyncStatus {
  AndroidForegroundSyncStatus({
    required this.runtimeState,
    required this.trustedPeerCount,
    required this.connectedPeerCount,
    required List<String> connectedPeerNames,
  }) : connectedPeerNames = List<String>.unmodifiable(connectedPeerNames) {
    if (trustedPeerCount < connectedPeerCount || connectedPeerCount < 0) {
      throw ArgumentError('Invalid trusted and connected peer counts');
    }
    if (connectedPeerNames.length > connectedPeerCount ||
        connectedPeerNames.length > _maxDisplayedPeerNames) {
      throw ArgumentError('Too many connected peer names');
    }
    if (connectedPeerNames.any((name) => name.trim().isEmpty)) {
      throw ArgumentError('Connected peer names must not be blank');
    }
    if (connectedPeerNames.any(
      (name) => name.runes.length > _maxPeerNameLength,
    )) {
      throw ArgumentError('Connected peer names are too long');
    }
  }

  static const int maxDisplayedPeerNames = _maxDisplayedPeerNames;
  static const int maxPeerNameLength = _maxPeerNameLength;

  final AndroidForegroundSyncRuntimeState runtimeState;
  final int trustedPeerCount;
  final int connectedPeerCount;
  final List<String> connectedPeerNames;

  @override
  bool operator ==(Object other) {
    if (other is! AndroidForegroundSyncStatus ||
        runtimeState != other.runtimeState ||
        trustedPeerCount != other.trustedPeerCount ||
        connectedPeerCount != other.connectedPeerCount ||
        connectedPeerNames.length != other.connectedPeerNames.length) {
      return false;
    }
    for (var index = 0; index < connectedPeerNames.length; index++) {
      if (connectedPeerNames[index] != other.connectedPeerNames[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        runtimeState,
        trustedPeerCount,
        connectedPeerCount,
        Object.hashAll(connectedPeerNames),
      );
}

typedef ListTrustedPeers = Future<Map<String, dynamic>> Function();

typedef PublishForegroundSyncStatus = Future<bool> Function(
    AndroidForegroundSyncStatus status);

const int _maxDisplayedPeerNames = 5;
const int _maxPeerNameLength = 48;

String normalizeAndroidForegroundSyncPeerName(Object? value) {
  var normalized = value is String ? value : '';
  normalized = normalized.trim().replaceAll(RegExp(r'\s+'), ' ');
  normalized = String.fromCharCodes(
    normalized.runes.where((rune) => !_isControlCharacter(rune)),
  ).trim();
  if (normalized.isEmpty) {
    return 'Trusted device';
  }

  final runes = normalized.runes;
  if (runes.length <= _maxPeerNameLength) {
    return normalized;
  }
  return String.fromCharCodes(runes.take(_maxPeerNameLength));
}

AndroidForegroundSyncStatus calculateAndroidForegroundSyncStatus(
  Map<String, dynamic> response, {
  AndroidForegroundSyncRuntimeState runtimeState =
      AndroidForegroundSyncRuntimeState.ready,
}) {
  final trustedPeers = <_ConnectedPeer>[];
  var trustedPeerCount = 0;
  final peers = response['peers'];
  if (peers is List) {
    for (final value in peers) {
      if (value is! Map) {
        continue;
      }

      final trustState = value['trustState']?.toString().toLowerCase();
      if (trustState != 'trusted') {
        continue;
      }
      trustedPeerCount++;

      final presence = value['presence']?.toString().toLowerCase();
      if (presence != 'online') {
        continue;
      }

      trustedPeers.add(
        _ConnectedPeer(
          deviceId: value['deviceId']?.toString() ?? '',
          displayName: normalizeAndroidForegroundSyncPeerName(
            value['displayName'],
          ),
        ),
      );
    }
  }

  trustedPeers.sort((left, right) {
    final nameComparison = left.displayName
        .toLowerCase()
        .compareTo(right.displayName.toLowerCase());
    if (nameComparison != 0) {
      return nameComparison;
    }
    return left.deviceId.compareTo(right.deviceId);
  });

  return AndroidForegroundSyncStatus(
    runtimeState: runtimeState,
    trustedPeerCount: trustedPeerCount,
    connectedPeerCount: trustedPeers.length,
    connectedPeerNames: trustedPeers
        .take(_maxDisplayedPeerNames)
        .map((peer) => peer.displayName)
        .toList(growable: false),
  );
}

class AndroidForegroundSyncStatusController {
  AndroidForegroundSyncStatusController({
    required ListTrustedPeers listTrustedPeers,
    required PublishForegroundSyncStatus publishForegroundSyncStatus,
    Stream<dynamic>? onTrustChanged,
    Stream<dynamic>? onPeerDiscovered,
    Stream<dynamic>? onPeerLost,
    Stream<dynamic>? onDeviceStatusUpdated,
    Stream<bool>? onConnectionChanged,
    Duration debounce = const Duration(milliseconds: 400),
    Duration healingRefreshInterval = const Duration(seconds: 60),
    void Function(String message)? logger,
  })  : _listTrustedPeers = listTrustedPeers,
        _publishForegroundSyncStatus = publishForegroundSyncStatus,
        _onTrustChanged = onTrustChanged,
        _onPeerDiscovered = onPeerDiscovered,
        _onPeerLost = onPeerLost,
        _onDeviceStatusUpdated = onDeviceStatusUpdated,
        _onConnectionChanged = onConnectionChanged,
        _debounceDuration = debounce,
        _healingRefreshInterval = healingRefreshInterval,
        _logger = logger {
    if (debounce.isNegative) {
      throw ArgumentError.value(debounce, 'debounce');
    }
    if (healingRefreshInterval <= Duration.zero) {
      throw ArgumentError.value(
        healingRefreshInterval,
        'healingRefreshInterval',
      );
    }
  }

  final ListTrustedPeers _listTrustedPeers;
  final PublishForegroundSyncStatus _publishForegroundSyncStatus;
  final Stream<dynamic>? _onTrustChanged;
  final Stream<dynamic>? _onPeerDiscovered;
  final Stream<dynamic>? _onPeerLost;
  final Stream<dynamic>? _onDeviceStatusUpdated;
  final Stream<bool>? _onConnectionChanged;
  final Duration _debounceDuration;
  final Duration _healingRefreshInterval;
  final void Function(String message)? _logger;

  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  Timer? _debounceTimer;
  Timer? _healingTimer;
  Future<void>? _startFuture;
  Future<void>? _refreshInFlight;
  Future<void>? _disposeFuture;
  bool _started = false;
  bool _disposed = false;
  bool _refreshDirty = false;
  AndroidForegroundSyncRuntimeState _runtimeState =
      AndroidForegroundSyncRuntimeState.starting;
  _PeerSnapshot? _lastPeerSnapshot;
  AndroidForegroundSyncStatus? _lastPublishedStatus;

  bool get isDisposed => _disposed;

  Future<void> start() {
    if (_disposed) {
      return Future<void>.value();
    }
    final existing = _startFuture;
    if (existing != null) {
      return existing;
    }

    _started = true;
    _runtimeState = AndroidForegroundSyncRuntimeState.ready;
    _subscribeToRefreshStream(_onTrustChanged);
    _subscribeToRefreshStream(_onPeerDiscovered);
    _subscribeToRefreshStream(_onPeerLost);
    _subscribeToRefreshStream(_onDeviceStatusUpdated);
    _subscribeToConnectionStream(_onConnectionChanged);
    _healingTimer = Timer.periodic(
      _healingRefreshInterval,
      (_) => _requestRefresh(),
    );

    final future = _beginRefresh();
    _startFuture = future;
    return future;
  }

  void requestRefresh() => _requestRefresh();

  Future<void> refreshNow() {
    if (!_started || _disposed) {
      return Future<void>.value();
    }
    _requestRefresh(immediate: true);
    return _refreshInFlight ?? Future<void>.value();
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  void _subscribeToRefreshStream(Stream<dynamic>? stream) {
    if (stream == null) {
      return;
    }
    _subscriptions.add(
      stream.listen(
        (_) => _requestRefresh(),
        onError: (Object error, StackTrace stackTrace) {
          _logger?.call('Foreground sync refresh stream failed: $error');
        },
      ),
    );
  }

  void _subscribeToConnectionStream(Stream<bool>? stream) {
    if (stream == null) {
      return;
    }
    _subscriptions.add(
      stream.listen(
        _handleConnectionChanged,
        onError: (Object error, StackTrace stackTrace) {
          _logger?.call('Foreground sync connection stream failed: $error');
        },
      ),
    );
  }

  void _handleConnectionChanged(bool isConnected) {
    if (!_started || _disposed) {
      return;
    }
    if (!isConnected) {
      _runtimeState = AndroidForegroundSyncRuntimeState.reconnecting;
      unawaited(_publishCurrentStatus());
      return;
    }

    _runtimeState = AndroidForegroundSyncRuntimeState.ready;
    _requestRefresh(immediate: true);
  }

  void _requestRefresh({bool immediate = false}) {
    if (!_started || _disposed) {
      return;
    }
    if (_refreshInFlight != null) {
      _refreshDirty = true;
      return;
    }

    if (immediate) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      unawaited(_beginRefresh());
      return;
    }

    if (_debounceTimer != null) {
      return;
    }
    _debounceTimer = Timer(_debounceDuration, () {
      _debounceTimer = null;
      unawaited(_beginRefresh());
    });
  }

  Future<void> _beginRefresh() {
    if (!_started || _disposed) {
      return Future<void>.value();
    }
    final existing = _refreshInFlight;
    if (existing != null) {
      _refreshDirty = true;
      return existing;
    }

    late final Future<void> refreshFuture;
    refreshFuture = _performRefresh();
    _refreshInFlight = refreshFuture;
    unawaited(
      refreshFuture.then<void>(
        (_) => _finishRefresh(refreshFuture),
        onError: (Object error, StackTrace stackTrace) {
          _finishRefresh(refreshFuture);
        },
      ),
    );
    return refreshFuture;
  }

  Future<void> _performRefresh() async {
    try {
      final response = await _listTrustedPeers();
      if (_disposed) {
        return;
      }
      final status = calculateAndroidForegroundSyncStatus(
        response,
        runtimeState: _runtimeState,
      );
      _lastPeerSnapshot = _PeerSnapshot.fromStatus(status);
      await _publishCurrentStatus();
    } catch (error) {
      _logger?.call('Foreground sync peer refresh failed: $error');
      if (!_disposed) {
        await _publishCurrentStatus();
      }
    }
  }

  void _finishRefresh(Future<void> refreshFuture) {
    if (!identical(_refreshInFlight, refreshFuture)) {
      return;
    }
    _refreshInFlight = null;
    if (_refreshDirty && !_disposed) {
      _refreshDirty = false;
      _requestRefresh(immediate: true);
    }
  }

  Future<void> _publishCurrentStatus() async {
    if (!_started || _disposed) {
      return;
    }
    final snapshot = _lastPeerSnapshot;
    if (snapshot == null &&
        _runtimeState == AndroidForegroundSyncRuntimeState.ready) {
      return;
    }
    final status =
        (snapshot ?? const _PeerSnapshot.empty()).toStatus(_runtimeState);
    if (_lastPublishedStatus == status) {
      return;
    }

    try {
      final accepted = await _publishForegroundSyncStatus(status);
      if (!_disposed && accepted) {
        _lastPublishedStatus = status;
      }
    } catch (error) {
      _logger?.call('Foreground sync status publication failed: $error');
    }
  }

  Future<void> _dispose() async {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _healingTimer?.cancel();
    _healingTimer = null;
    _refreshDirty = false;

    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    final refreshInFlight = _refreshInFlight;
    if (refreshInFlight != null) {
      try {
        await refreshInFlight;
      } catch (_) {
        // Refresh failures are non-fatal to runtime shutdown.
      }
    }
  }
}

class _ConnectedPeer {
  const _ConnectedPeer({required this.deviceId, required this.displayName});

  final String deviceId;
  final String displayName;
}

class _PeerSnapshot {
  const _PeerSnapshot({
    required this.trustedPeerCount,
    required this.connectedPeerCount,
    required this.connectedPeerNames,
  });

  const _PeerSnapshot.empty()
      : trustedPeerCount = 0,
        connectedPeerCount = 0,
        connectedPeerNames = const <String>[];

  factory _PeerSnapshot.fromStatus(AndroidForegroundSyncStatus status) {
    return _PeerSnapshot(
      trustedPeerCount: status.trustedPeerCount,
      connectedPeerCount: status.connectedPeerCount,
      connectedPeerNames: status.connectedPeerNames,
    );
  }

  final int trustedPeerCount;
  final int connectedPeerCount;
  final List<String> connectedPeerNames;

  AndroidForegroundSyncStatus toStatus(
    AndroidForegroundSyncRuntimeState runtimeState,
  ) {
    return AndroidForegroundSyncStatus(
      runtimeState: runtimeState,
      trustedPeerCount: trustedPeerCount,
      connectedPeerCount: connectedPeerCount,
      connectedPeerNames: connectedPeerNames,
    );
  }
}

bool _isControlCharacter(int rune) =>
    (rune >= 0 && rune <= 0x1f) || (rune >= 0x7f && rune <= 0x9f);
