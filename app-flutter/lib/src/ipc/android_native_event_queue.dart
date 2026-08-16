import 'dart:async';
import 'dart:collection';

const defaultAndroidNativeEventQueueCapacity = 256;
const defaultAndroidNativeStateDispatchAttempts = 3;

enum AndroidNativeEventKind {
  notificationState,
  mediaPlaybackState,
  mediaPlaybackAction,
}

enum AndroidNativeEventDispatchResult {
  delivered,
  retryLater,
  drop,
}

typedef AndroidNativeEventDispatcher = Future<AndroidNativeEventDispatchResult>
    Function(
  AndroidNativeEvent event,
);

typedef AndroidNativeEventLogger = void Function(String message);

class AndroidNativeEvent {
  AndroidNativeEvent._({
    required this.kind,
    required this.eventType,
    required this.payload,
    required this.entityKey,
    required this.connectionGeneration,
  });

  final AndroidNativeEventKind kind;
  final String eventType;
  final Map<String, dynamic> payload;
  final String entityKey;
  final int connectionGeneration;

  int _dispatchAttempts = 0;

  int get dispatchAttempts => _dispatchAttempts;

  bool get isState => kind != AndroidNativeEventKind.mediaPlaybackAction;

  bool get isRemoval => isState && eventType == 'removed';

  bool get requiresNotificationPolicy =>
      kind == AndroidNativeEventKind.notificationState && !isRemoval;
}

/// Buffers Android state for eventual convergence while keeping media actions
/// ephemeral. State may coalesce and survive a disconnect; commands belong to
/// one IPC generation and are never replayed in a later generation.
class AndroidNativeEventQueue {
  AndroidNativeEventQueue({
    required AndroidNativeEventDispatcher dispatch,
    AndroidNativeEventLogger? logger,
    this.capacity = defaultAndroidNativeEventQueueCapacity,
    this.maxStateDispatchAttempts = defaultAndroidNativeStateDispatchAttempts,
  })  : assert(capacity > 0),
        assert(maxStateDispatchAttempts > 0),
        _dispatch = dispatch,
        _logger = logger;

  static const _mediaActions = <String>{
    'play',
    'pause',
    'togglePlayPause',
    'next',
    'previous',
    'seek',
  };

  final AndroidNativeEventDispatcher _dispatch;
  final AndroidNativeEventLogger? _logger;
  final int capacity;
  final int maxStateDispatchAttempts;
  final List<AndroidNativeEvent> _events = <AndroidNativeEvent>[];

  bool _isConnected = false;
  bool _notificationPolicyReady = false;
  int _connectionGeneration = 0;
  bool _flushRequested = false;
  bool _disposed = false;
  Completer<void>? _activeFlush;

  int get length => _events.length;

  bool get isEmpty => _events.isEmpty;

  bool get isConnected => _isConnected;

  bool get notificationPolicyReady => _notificationPolicyReady;

  int get connectionGeneration => _connectionGeneration;

  bool get isDisposed => _disposed;

  List<AndroidNativeEvent> get queuedEvents =>
      List<AndroidNativeEvent>.unmodifiable(_events);

  void onConnected() {
    if (_disposed || _isConnected) {
      return;
    }
    if (_connectionGeneration == 0) {
      _connectionGeneration = 1;
    }
    _isConnected = true;
    _log(
      'IPC connected generation=$_connectionGeneration '
      'queueLength=${_events.length}',
    );
    _wakeActiveFlush();
  }

  void onConnectionLost() {
    if (_disposed) return;
    if (_isConnected) {
      _connectionGeneration += 1;
    }
    _isConnected = false;
    _notificationPolicyReady = false;

    final previousLength = _events.length;
    _events.removeWhere(
      (event) => event.kind == AndroidNativeEventKind.mediaPlaybackAction,
    );
    final droppedCommands = previousLength - _events.length;
    if (droppedCommands > 0) {
      _log(
        'stale media commands dropped count=$droppedCommands '
        'generation=$_connectionGeneration queueLength=${_events.length}',
      );
    }
    _log(
      'IPC disconnected generation=$_connectionGeneration '
      'retainedState=${_events.length}',
    );
  }

  void setNotificationPolicyReady(bool isReady) {
    if (_disposed || _notificationPolicyReady == isReady) {
      return;
    }
    _notificationPolicyReady = isReady;
    _log(
      'notification policy ready=$isReady queueLength=${_events.length}',
    );
    _wakeActiveFlush();
  }

  bool enqueue(Map<String, dynamic> payload) {
    if (_disposed) {
      _log('native event dropped because queue is disposed');
      return false;
    }
    final validation = _validate(payload);
    final event = validation.event;
    if (event == null) {
      _log('invalid native event dropped reason=${validation.failureReason}');
      return false;
    }

    if (event.kind == AndroidNativeEventKind.mediaPlaybackAction &&
        !_isConnected) {
      _log(
        'stale media command dropped while disconnected '
        '${_identity(event)} generation=$_connectionGeneration',
      );
      return false;
    }

    if (event.isState) {
      final existingIndex = _events.indexWhere(
        (queued) =>
            queued.isState &&
            queued.kind == event.kind &&
            queued.entityKey == event.entityKey,
      );
      if (existingIndex >= 0) {
        final previous = _events[existingIndex];
        _events[existingIndex] = _coalesce(previous, event);
        _log(
          'native state event coalesced ${_identity(event)} '
          '${previous.eventType}->${_events[existingIndex].eventType} '
          'queueLength=${_events.length}',
        );
        _wakeActiveFlush();
        return true;
      }
    }

    if (!_makeRoomFor(event)) {
      return false;
    }

    _events.add(event);
    _log(
      'native event queued kind=${event.kind.name} ${_identity(event)} '
      'generation=${event.connectionGeneration} queueLength=${_events.length}',
    );
    _wakeActiveFlush();
    return true;
  }

  Future<void> flush() {
    if (_disposed) {
      return Future<void>.value();
    }
    _flushRequested = true;
    final activeFlush = _activeFlush;
    if (activeFlush != null) {
      return activeFlush.future;
    }

    final completer = Completer<void>();
    _activeFlush = completer;
    unawaited(_runFlush(completer));
    return completer.future;
  }

  Future<void> _runFlush(Completer<void> completer) async {
    Object? failure;
    StackTrace? failureStackTrace;
    _log(
      'native event queue drain started generation=$_connectionGeneration '
      'queueLength=${_events.length}',
    );
    try {
      while (_flushRequested) {
        _flushRequested = false;
        await _drainPass();
      }
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    } finally {
      _log(
        'native event queue drain completed generation=$_connectionGeneration '
        'queueLength=${_events.length}',
      );
      _activeFlush = null;
      if (failure == null) {
        completer.complete();
      } else {
        completer.completeError(failure, failureStackTrace);
      }
      if (_flushRequested) {
        unawaited(flush());
      }
    }
  }

  Future<void> _drainPass() async {
    final attempted = HashSet<AndroidNativeEvent>.identity();
    final policyWaitLogged = HashSet<AndroidNativeEvent>.identity();

    while (_isConnected) {
      final event = _nextEligibleEvent(attempted, policyWaitLogged);
      if (event == null) {
        return;
      }
      attempted.add(event);
      event._dispatchAttempts += 1;

      AndroidNativeEventDispatchResult result;
      try {
        result = await _dispatch(event);
      } catch (error) {
        _log(
          'native event permanently rejected ${_identity(event)} '
          'attempt=${event.dispatchAttempts} errorType=${error.runtimeType}',
        );
        result = AndroidNativeEventDispatchResult.drop;
      }

      final currentIndex = _events.indexOf(event);
      if (currentIndex < 0) {
        continue;
      }

      switch (result) {
        case AndroidNativeEventDispatchResult.delivered:
          _events.removeAt(currentIndex);
          break;
        case AndroidNativeEventDispatchResult.drop:
          _events.removeAt(currentIndex);
          _log(
            'native event permanently rejected ${_identity(event)} '
            'attempt=${event.dispatchAttempts} queueLength=${_events.length}',
          );
          break;
        case AndroidNativeEventDispatchResult.retryLater:
          if (!event.isState) {
            _events.removeAt(currentIndex);
            _log(
              'stale media command dropped after dispatch failure '
              '${_identity(event)} generation=${event.connectionGeneration}',
            );
          } else if (event.dispatchAttempts >= maxStateDispatchAttempts) {
            _events.removeAt(currentIndex);
            _log(
              'native state retry budget exhausted ${_identity(event)} '
              'attempt=${event.dispatchAttempts} queueLength=${_events.length}',
            );
          } else {
            _log(
              'native state event retained for reconnect ${_identity(event)} '
              'attempt=${event.dispatchAttempts} queueLength=${_events.length}',
            );
          }
          break;
      }
    }
  }

  AndroidNativeEvent? _nextEligibleEvent(
    Set<AndroidNativeEvent> attempted,
    Set<AndroidNativeEvent> policyWaitLogged,
  ) {
    var index = 0;
    while (index < _events.length) {
      final event = _events[index];
      if (event.kind == AndroidNativeEventKind.mediaPlaybackAction &&
          event.connectionGeneration != _connectionGeneration) {
        _events.removeAt(index);
        _log(
          'stale media command dropped ${_identity(event)} '
          'eventGeneration=${event.connectionGeneration} '
          'connectionGeneration=$_connectionGeneration',
        );
        continue;
      }
      if (attempted.contains(event)) {
        index += 1;
        continue;
      }
      if (event.requiresNotificationPolicy && !_notificationPolicyReady) {
        if (policyWaitLogged.add(event)) {
          _log(
            'notification event waiting for policy ${_identity(event)} '
            'queueLength=${_events.length}',
          );
        }
        index += 1;
        continue;
      }
      return event;
    }
    return null;
  }

  _NativeEventValidation _validate(Map<String, dynamic> rawPayload) {
    final payload = Map<String, dynamic>.from(rawPayload);
    final rawEventType = payload['eventType'];
    if (rawEventType is! String || rawEventType.trim().isEmpty) {
      return const _NativeEventValidation.invalid('eventType missing');
    }
    final eventType = rawEventType;

    if (eventType == 'mediaPlaybackAction') {
      final sourceDeviceId = _nonBlankString(payload, 'sourceDeviceId');
      final playbackId = _nonBlankString(payload, 'playbackId');
      final action = _nonBlankString(payload, 'action');
      if (sourceDeviceId == null || playbackId == null || action == null) {
        return const _NativeEventValidation.invalid(
          'media action identity missing',
        );
      }
      if (!_mediaActions.contains(action)) {
        return const _NativeEventValidation.invalid('unknown media action');
      }

      final rawPositionMs = payload['positionMs'];
      if (rawPositionMs != null) {
        if (!_isValidPosition(rawPositionMs)) {
          return const _NativeEventValidation.invalid(
            'invalid media action position',
          );
        }
        payload['positionMs'] = (rawPositionMs as num).toInt();
      } else if (action == 'seek') {
        return const _NativeEventValidation.invalid(
          'seek position missing',
        );
      }

      return _NativeEventValidation.valid(
        AndroidNativeEvent._(
          kind: AndroidNativeEventKind.mediaPlaybackAction,
          eventType: eventType,
          payload: Map<String, dynamic>.unmodifiable(payload),
          entityKey: '$sourceDeviceId\n$playbackId',
          connectionGeneration: _connectionGeneration,
        ),
      );
    }

    if (eventType != 'posted' &&
        eventType != 'updated' &&
        eventType != 'removed') {
      return const _NativeEventValidation.invalid('unknown eventType');
    }

    final hasNotificationId = payload.containsKey('notificationId');
    final hasPlaybackId = payload.containsKey('playbackId');
    if (hasNotificationId == hasPlaybackId) {
      return const _NativeEventValidation.invalid('ambiguous state identity');
    }

    final identityKey = hasNotificationId ? 'notificationId' : 'playbackId';
    final entityKey = _nonBlankString(payload, identityKey);
    if (entityKey == null) {
      return _NativeEventValidation.invalid('$identityKey missing');
    }

    return _NativeEventValidation.valid(
      AndroidNativeEvent._(
        kind: hasNotificationId
            ? AndroidNativeEventKind.notificationState
            : AndroidNativeEventKind.mediaPlaybackState,
        eventType: eventType,
        payload: Map<String, dynamic>.unmodifiable(payload),
        entityKey: entityKey,
        connectionGeneration: _connectionGeneration,
      ),
    );
  }

  AndroidNativeEvent _coalesce(
    AndroidNativeEvent previous,
    AndroidNativeEvent latest,
  ) {
    var eventType = latest.eventType;
    if (latest.eventType == 'updated' && previous.eventType == 'posted') {
      eventType = 'posted';
    } else if (latest.eventType == 'updated' &&
        previous.eventType == 'removed') {
      eventType = 'posted';
    }

    final payload = Map<String, dynamic>.from(latest.payload)
      ..['eventType'] = eventType;
    return AndroidNativeEvent._(
      kind: latest.kind,
      eventType: eventType,
      payload: Map<String, dynamic>.unmodifiable(payload),
      entityKey: latest.entityKey,
      connectionGeneration: latest.connectionGeneration,
    );
  }

  bool _makeRoomFor(AndroidNativeEvent incoming) {
    if (_events.length < capacity) {
      return true;
    }

    if (!incoming.isState) {
      _log(
        'native event dropped on queue overflow ${_identity(incoming)} '
        'queueLength=${_events.length} capacity=$capacity',
      );
      return false;
    }

    var victimIndex = _events.indexWhere((event) => !event.isState);
    if (victimIndex < 0) {
      victimIndex = _events.indexWhere((event) => !event.isRemoval);
    }
    if (victimIndex < 0 && incoming.isRemoval) {
      victimIndex = 0;
    }
    if (victimIndex < 0) {
      _log(
        'native state dropped on queue overflow ${_identity(incoming)} '
        'queueLength=${_events.length} capacity=$capacity',
      );
      return false;
    }

    final victim = _events.removeAt(victimIndex);
    _log(
      'queue overflow eviction evicted=${_identity(victim)} '
      'incoming=${_identity(incoming)} queueLength=${_events.length} '
      'capacity=$capacity',
    );
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isConnected = false;
    _notificationPolicyReady = false;
    _connectionGeneration += 1;
    _flushRequested = false;
    final droppedEvents = _events.length;
    _events.clear();
    _log(
      'native event queue disposed generation=$_connectionGeneration '
      'droppedEvents=$droppedEvents',
    );
  }

  void _wakeActiveFlush() {
    if (_activeFlush != null) {
      _flushRequested = true;
    }
  }

  void _log(String message) {
    _logger?.call(message);
  }

  static String? _nonBlankString(
    Map<String, dynamic> payload,
    String key,
  ) {
    final value = payload[key];
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return value;
  }

  static bool _isValidPosition(Object value) {
    if (value is! num || !value.isFinite || value < 0) {
      return false;
    }
    return value == value.toInt();
  }

  static String _identity(AndroidNativeEvent event) {
    if (event.kind == AndroidNativeEventKind.mediaPlaybackAction) {
      return 'sourceDeviceId=${event.payload['sourceDeviceId']} '
          'playbackId=${event.payload['playbackId']} '
          'action=${event.payload['action']}';
    }
    final key = event.kind == AndroidNativeEventKind.notificationState
        ? 'notificationId'
        : 'playbackId';
    return '$key=${event.payload[key]} eventType=${event.eventType}';
  }
}

class _NativeEventValidation {
  const _NativeEventValidation.valid(this.event) : failureReason = null;

  const _NativeEventValidation.invalid(this.failureReason) : event = null;

  final AndroidNativeEvent? event;
  final String? failureReason;
}
