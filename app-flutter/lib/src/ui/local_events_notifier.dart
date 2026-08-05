import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ipc/json_rpc_client.dart';

enum LocalEventKind {
  deviceConnected,
  deviceDisconnected,
  deviceTrusted,
  devicePairingRequest,
  clipboardReceived,
  clipboardExpired,
  fileReceived,
  fileFailed,
}

class LocalEvent {
  LocalEvent({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.identityKey,
    required this.reconciliationKey,
    this.reconciliationSubject,
    this.isSecurityNotification = false,
    this.eventId,
    this.peerDeviceId,
  });

  final LocalEventKind kind;
  final String title;
  final String subtitle;
  final DateTime time;
  final String identityKey;
  final String reconciliationKey;
  final String? reconciliationSubject;
  final bool isSecurityNotification;
  final String? eventId;
  final String? peerDeviceId;
}

class LocalEventsNotifier extends ChangeNotifier {
  static const _maxEvents = 50;
  static const _reconciliationWindow = Duration(seconds: 30);

  final JsonRpcRiftClient _client;
  final List<LocalEvent> _events = [];
  final Set<LocalEvent> _historyEvents = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _historyLoading = false;

  LocalEventsNotifier(this._client) {
    _subs.addAll([
      _client.onTrustChanged.listen(_onTrustChanged),
      _client.onPairingRequest.listen(_onPairingRequest),
      _client.onPairingComplete.listen(_onPairingComplete),
      _client.onClipboardOffer.listen(_onClipboardOffer),
      _client.onClipboardExpired.listen(_onClipboardExpired),
      _client.onFileTransferCompleted.listen(_onFileCompleted),
      _client.onFileTransferFailed.listen(_onFileFailed),
      _client.onSecurityEvent.listen(_onSecurityEvent),
      _client.onConnectionChanged.listen((isConnected) {
        if (isConnected) unawaited(_loadHistory());
      }),
    ]);
    unawaited(_loadHistory());
  }

  List<LocalEvent> get events => List.unmodifiable(_events);
  int get unreadCount => _unreadCount;
  int _unreadCount = 0;

  void markAllRead() {
    _unreadCount = 0;
    notifyListeners();
  }

  void _add(LocalEvent event, {bool unread = true}) {
    final exactIndex = _events
        .indexWhere((existing) => existing.identityKey == event.identityKey);
    if (exactIndex >= 0) {
      _events.removeAt(exactIndex);
    } else {
      final reconciliationIndex = _closestReconciliationMatch(
        _events,
        event,
        excluded: _historyEvents,
        requireSecuritySourceDifference: true,
      );
      if (reconciliationIndex >= 0) _events.removeAt(reconciliationIndex);
    }
    _events.insert(0, event);
    if (_events.length > _maxEvents) _events.removeLast();
    if (unread) _unreadCount++;
    notifyListeners();
  }

  Future<void> _loadHistory() async {
    if (!_client.isConnected || _historyLoading) return;
    _historyLoading = true;
    final loadStartedAt = DateTime.now();
    try {
      final result = await _client.queryEventLog(
        eventTypes: const [
          'connection.established',
          'connection.lost',
          'trust.transitioned',
          'pairing.attempted',
          'pairing.completed',
          'clipboard.offered',
          'clipboard.expired',
          'file_transfer.rejected',
        ],
        limit: _maxEvents,
      );
      final records = List<Map<String, dynamic>>.from(
        (result['events'] as List? ?? const <dynamic>[])
            .map((event) => Map<String, dynamic>.from(event as Map)),
      );
      final historyEvents = records
          .map(_fromSecurityEvent)
          .whereType<LocalEvent>()
          .toList(growable: false);
      final liveEvents = _events
          .where((event) => !_historyEvents.contains(event))
          .toList(growable: true);
      final matchedLiveEvents = <LocalEvent>{};
      for (final historyEvent in historyEvents) {
        final exactMatch = liveEvents.indexWhere(
          (event) =>
              !matchedLiveEvents.contains(event) &&
              event.identityKey == historyEvent.identityKey,
        );
        if (exactMatch >= 0) {
          matchedLiveEvents.add(liveEvents[exactMatch]);
          continue;
        }
        final reconciliationMatch = _closestReconciliationMatch(
          liveEvents,
          historyEvent,
          excluded: matchedLiveEvents,
          latestCandidateTime: loadStartedAt,
        );
        if (reconciliationMatch >= 0) {
          matchedLiveEvents.add(liveEvents[reconciliationMatch]);
        }
      }
      _historyEvents
        ..clear()
        ..addAll(historyEvents);
      _events
        ..clear()
        ..addAll(
            liveEvents.where((event) => !matchedLiveEvents.contains(event)))
        ..addAll(historyEvents)
        ..sort((a, b) => b.time.compareTo(a.time));
      if (_events.length > _maxEvents) {
        _events.removeRange(_maxEvents, _events.length);
      }
      notifyListeners();
    } catch (_) {
      // The live feed remains available when event history is unsupported.
    } finally {
      _historyLoading = false;
    }
  }

  int _closestReconciliationMatch(
    List<LocalEvent> candidates,
    LocalEvent target, {
    Set<LocalEvent> excluded = const {},
    DateTime? latestCandidateTime,
    bool requireSecuritySourceDifference = false,
  }) {
    var closestIndex = -1;
    Duration? closestDifference;
    for (var index = 0; index < candidates.length; index += 1) {
      final candidate = candidates[index];
      if (excluded.contains(candidate)) continue;
      if (latestCandidateTime != null &&
          !candidate.time.isBefore(latestCandidateTime)) {
        continue;
      }
      if (requireSecuritySourceDifference &&
          candidate.isSecurityNotification == target.isSecurityNotification) {
        continue;
      }
      if (candidate.reconciliationKey != target.reconciliationKey) continue;
      final candidateSubject = candidate.reconciliationSubject;
      final targetSubject = target.reconciliationSubject;
      if (candidateSubject != null &&
          targetSubject != null &&
          candidateSubject != targetSubject) {
        continue;
      }
      final difference = candidate.time.difference(target.time).abs();
      if (difference > _reconciliationWindow) continue;
      if (closestDifference == null || difference < closestDifference) {
        closestIndex = index;
        closestDifference = difference;
      }
    }
    return closestIndex;
  }

  LocalEvent? _fromSecurityEvent(Map<String, dynamic> record) {
    final type = record['eventType']?.toString() ?? '';
    final eventId = record['eventId']?.toString();
    final peerDeviceId = record['peerDeviceId']?.toString();
    final peer = _shortId(peerDeviceId ?? '');
    final time =
        DateTime.tryParse(record['timestamp']?.toString() ?? '')?.toLocal() ??
            DateTime.now();
    final identityKey = _buildIdentityKey(
      eventId: eventId,
      eventType: type,
      peerDeviceId: peerDeviceId,
      subject: record['details']?.toString(),
      timestamp: record['timestamp']?.toString(),
    );
    final reconciliationKey = _buildReconciliationKey(type, peerDeviceId);
    final reconciliationSubject = _eventSubject(
      type,
      record['details'],
    );

    return switch (type) {
      'connection.established' => LocalEvent(
          kind: LocalEventKind.deviceConnected,
          title: 'Device connected',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      'connection.lost' => LocalEvent(
          kind: LocalEventKind.deviceDisconnected,
          title: 'Device disconnected',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      'trust.transitioned' => LocalEvent(
          kind: LocalEventKind.deviceTrusted,
          title: 'Trust updated',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      'pairing.attempted' => LocalEvent(
          kind: LocalEventKind.devicePairingRequest,
          title: 'Pairing activity',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      'pairing.completed' => LocalEvent(
          kind: LocalEventKind.deviceTrusted,
          title: 'Pairing completed',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      'clipboard.offered' => LocalEvent(
          kind: LocalEventKind.clipboardReceived,
          title: 'Clipboard received',
          subtitle: peer.isEmpty ? 'Incoming clipboard offer' : 'From $peer',
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      'clipboard.expired' => LocalEvent(
          kind: LocalEventKind.clipboardExpired,
          title: 'Clipboard offer expired',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      'file_transfer.rejected' => LocalEvent(
          kind: LocalEventKind.fileFailed,
          title: 'File transfer rejected',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
          reconciliationSubject: reconciliationSubject,
          isSecurityNotification: true,
          eventId: eventId,
          peerDeviceId: peerDeviceId,
        ),
      _ => null,
    };
  }

  void _onSecurityEvent(Map<String, dynamic> record) {
    final event = _fromSecurityEvent(record);
    if (event != null) _add(event);
  }

  void _onTrustChanged(Map<String, dynamic> e) {
    final deviceId = e['deviceId']?.toString() ?? '';
    final previousState = e['previousState']?.toString() ?? '';
    final newState = e['newState']?.toString() ?? '';
    final transition = '$previousState>$newState';
    final name = e['displayName']?.toString() ?? _shortId(deviceId);
    final eventId = e['eventId']?.toString();
    final time = DateTime.now();
    late final LocalEventKind kind;
    late final String title;
    switch (newState) {
      case 'trusted':
        kind = LocalEventKind.deviceTrusted;
        title = 'Device trusted';
      case 'discovered':
        kind = LocalEventKind.deviceConnected;
        title = 'Device discovered';
      case 'blocked':
        kind = LocalEventKind.deviceDisconnected;
        title = 'Device blocked';
      default:
        return;
    }
    _add(LocalEvent(
      kind: kind,
      title: title,
      subtitle: name,
      time: time,
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'trust.transitioned',
        peerDeviceId: deviceId,
        subject: transition,
        timestamp: time.toIso8601String(),
      ),
      reconciliationKey: _buildReconciliationKey(
        'trust.transitioned',
        deviceId,
      ),
      reconciliationSubject: transition,
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onPairingRequest(Map<String, dynamic> e) {
    final deviceId = e['deviceId']?.toString() ?? '';
    final fingerprint = e['fingerprint']?.toString();
    final eventId = e['eventId']?.toString();
    final time = DateTime.now();
    _add(LocalEvent(
      kind: LocalEventKind.devicePairingRequest,
      title: 'Pairing request',
      subtitle: e['displayName']?.toString() ?? _shortId(deviceId),
      time: time,
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'pairing.attempted',
        peerDeviceId: deviceId,
        subject: fingerprint,
        timestamp: time.toIso8601String(),
      ),
      reconciliationKey: _buildReconciliationKey(
        'pairing.attempted',
        deviceId,
      ),
      reconciliationSubject: fingerprint,
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onPairingComplete(Map<String, dynamic> e) {
    final deviceId = e['deviceId']?.toString() ?? '';
    final subject =
        e['persistedAt']?.toString() ?? e['fingerprint']?.toString();
    final eventId = e['eventId']?.toString();
    final time = DateTime.now();
    _add(LocalEvent(
      kind: LocalEventKind.deviceTrusted,
      title: 'Pairing completed',
      subtitle: e['displayName']?.toString() ?? _shortId(deviceId),
      time: time,
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'pairing.completed',
        peerDeviceId: deviceId,
        subject: subject,
        timestamp: subject == null ? time.toIso8601String() : null,
      ),
      reconciliationKey: _buildReconciliationKey(
        'pairing.completed',
        deviceId,
      ),
      reconciliationSubject: subject,
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onClipboardOffer(Map<String, dynamic> e) {
    final deviceId = e['sourceDeviceId']?.toString() ?? '';
    final contentType = e['contentType']?.toString() ?? 'content';
    final label = contentType.startsWith('text/') ? 'Text' : 'File';
    final offerId = e['offerId']?.toString();
    final eventId = e['eventId']?.toString();
    final time = DateTime.now();
    _add(LocalEvent(
      kind: LocalEventKind.clipboardReceived,
      title: 'Clipboard received',
      subtitle: '$label from ${_shortId(deviceId)}',
      time: time,
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'clipboard.offered',
        peerDeviceId: deviceId,
        subject: offerId ?? contentType,
        timestamp: offerId == null ? time.toIso8601String() : null,
      ),
      reconciliationKey: _buildReconciliationKey(
        'clipboard.offered',
        deviceId,
      ),
      reconciliationSubject: offerId,
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onClipboardExpired(Map<String, dynamic> e) {
    final offerId = e['offerId']?.toString() ?? '';
    final eventId = e['eventId']?.toString();
    final time = DateTime.now();
    _add(LocalEvent(
      kind: LocalEventKind.clipboardExpired,
      title: 'Clipboard offer expired',
      subtitle: 'Offer ID: ${_shortId(offerId)}',
      time: time,
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'clipboard.expired',
        subject: offerId,
        timestamp: offerId.isEmpty ? time.toIso8601String() : null,
      ),
      reconciliationKey: _buildReconciliationKey('clipboard.expired', null),
      reconciliationSubject: offerId.isEmpty ? null : offerId,
      eventId: eventId,
    ));
  }

  void _onFileCompleted(Map<String, dynamic> e) {
    final fileName = e['fileName']?.toString() ?? 'file';
    final peerDeviceId = e['peerDeviceId']?.toString() ?? '';
    final transferId = e['transferId']?.toString();
    final eventId = e['eventId']?.toString();
    final time = DateTime.now();
    _add(LocalEvent(
      kind: LocalEventKind.fileReceived,
      title: 'File received',
      subtitle: fileName,
      time: time,
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'file_transfer.completed',
        peerDeviceId: peerDeviceId,
        subject: transferId ?? fileName,
        timestamp: transferId == null ? time.toIso8601String() : null,
      ),
      reconciliationKey: _buildReconciliationKey(
        'file_transfer.completed',
        peerDeviceId,
      ),
      reconciliationSubject: transferId,
      eventId: eventId,
      peerDeviceId: peerDeviceId,
    ));
  }

  void _onFileFailed(Map<String, dynamic> e) {
    final fileName = e['fileName']?.toString() ?? 'file';
    final peerDeviceId = e['peerDeviceId']?.toString() ?? '';
    final transferId = e['transferId']?.toString();
    final eventId = e['eventId']?.toString();
    final time = DateTime.now();
    _add(LocalEvent(
      kind: LocalEventKind.fileFailed,
      title: 'File transfer failed',
      subtitle: fileName,
      time: time,
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'file_transfer.failed',
        peerDeviceId: peerDeviceId,
        subject: transferId ?? fileName,
        timestamp: transferId == null ? time.toIso8601String() : null,
      ),
      reconciliationKey: _buildReconciliationKey(
        'file_transfer.rejected',
        peerDeviceId,
      ),
      reconciliationSubject: transferId,
      eventId: eventId,
      peerDeviceId: peerDeviceId,
    ));
  }

  String? _eventSubject(String eventType, Object? details) {
    if (details is! Map) return null;
    switch (eventType) {
      case 'clipboard.offered':
      case 'clipboard.expired':
        return details['offerId']?.toString();
      case 'file_transfer.rejected':
        return details['transferId']?.toString();
      case 'pairing.attempted':
      case 'pairing.completed':
        return details['persistedAt']?.toString() ??
            details['fingerprint']?.toString();
      case 'trust.transitioned':
        final previousState = details['previousState']?.toString();
        final newState = details['newState']?.toString();
        if (previousState == null && newState == null) return null;
        return '${previousState ?? ''}>${newState ?? ''}';
      default:
        return null;
    }
  }

  String _buildIdentityKey({
    String? eventId,
    required String eventType,
    String? peerDeviceId,
    String? subject,
    String? timestamp,
  }) {
    final normalizedEventId = eventId?.trim();
    if (normalizedEventId != null && normalizedEventId.isNotEmpty) {
      return 'event:$normalizedEventId';
    }
    return '$eventType|${peerDeviceId ?? ''}|${subject ?? ''}|${timestamp ?? ''}';
  }

  String _buildReconciliationKey(String eventType, String? peerDeviceId) {
    if (eventType == 'clipboard.expired') return eventType;
    return '$eventType|${peerDeviceId ?? ''}';
  }

  String _shortId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 12)}…';
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
