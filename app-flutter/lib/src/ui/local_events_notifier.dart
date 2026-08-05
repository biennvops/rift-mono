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
    this.eventId,
    this.peerDeviceId,
  });

  final LocalEventKind kind;
  final String title;
  final String subtitle;
  final DateTime time;
  final String identityKey;
  final String reconciliationKey;
  final String? eventId;
  final String? peerDeviceId;
}

class LocalEventsNotifier extends ChangeNotifier {
  static const _maxEvents = 50;

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
    _events.removeWhere(
      (existing) =>
          existing.identityKey == event.identityKey ||
          (existing.reconciliationKey == event.reconciliationKey &&
              existing.time.difference(event.time).abs() <=
                  const Duration(seconds: 5)),
    );
    _events.insert(0, event);
    if (_events.length > _maxEvents) _events.removeLast();
    if (unread) _unreadCount++;
    notifyListeners();
  }

  Future<void> _loadHistory() async {
    if (!_client.isConnected || _historyLoading) return;
    _historyLoading = true;
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
      final historyKeys = historyEvents.map((event) => event.identityKey);
      final historyReconciliationKeys =
          historyEvents.map((event) => event.reconciliationKey).toSet();
      _events.removeWhere(
        (event) =>
            _historyEvents.contains(event) ||
            historyKeys.contains(event.identityKey) ||
            historyReconciliationKeys.contains(event.reconciliationKey),
      );
      _historyEvents
        ..clear()
        ..addAll(historyEvents);
      _events
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

    return switch (type) {
      'connection.established' => LocalEvent(
          kind: LocalEventKind.deviceConnected,
          title: 'Device connected',
          subtitle: peer,
          time: time,
          identityKey: identityKey,
          reconciliationKey: reconciliationKey,
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
    final newState = e['newState']?.toString() ?? '';
    final name = e['displayName']?.toString() ?? _shortId(deviceId);
    final eventId = e['eventId']?.toString();
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
      time: DateTime.now(),
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'trust.transitioned',
        peerDeviceId: deviceId,
        subject: newState,
      ),
      reconciliationKey: _buildReconciliationKey(
        'trust.transitioned',
        deviceId,
      ),
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onPairingRequest(Map<String, dynamic> e) {
    final deviceId = e['deviceId']?.toString() ?? '';
    final eventId = e['eventId']?.toString();
    _add(LocalEvent(
      kind: LocalEventKind.devicePairingRequest,
      title: 'Pairing request',
      subtitle: e['displayName']?.toString() ?? _shortId(deviceId),
      time: DateTime.now(),
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'pairing.attempted',
        peerDeviceId: deviceId,
        subject: e['fingerprint']?.toString(),
      ),
      reconciliationKey: _buildReconciliationKey(
        'pairing.attempted',
        deviceId,
      ),
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onPairingComplete(Map<String, dynamic> e) {
    final deviceId = e['deviceId']?.toString() ?? '';
    final eventId = e['eventId']?.toString();
    _add(LocalEvent(
      kind: LocalEventKind.deviceTrusted,
      title: 'Pairing completed',
      subtitle: e['displayName']?.toString() ?? _shortId(deviceId),
      time: DateTime.now(),
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'pairing.completed',
        peerDeviceId: deviceId,
      ),
      reconciliationKey: _buildReconciliationKey(
        'pairing.completed',
        deviceId,
      ),
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onClipboardOffer(Map<String, dynamic> e) {
    final deviceId = e['sourceDeviceId']?.toString() ?? '';
    final contentType = e['contentType']?.toString() ?? 'content';
    final label = contentType.startsWith('text/') ? 'Text' : 'File';
    final eventId = e['eventId']?.toString();
    _add(LocalEvent(
      kind: LocalEventKind.clipboardReceived,
      title: 'Clipboard received',
      subtitle: '$label from ${_shortId(deviceId)}',
      time: DateTime.now(),
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'clipboard.offered',
        peerDeviceId: deviceId,
        subject: e['offerId']?.toString() ?? contentType,
      ),
      reconciliationKey: _buildReconciliationKey(
        'clipboard.offered',
        deviceId,
      ),
      eventId: eventId,
      peerDeviceId: deviceId,
    ));
  }

  void _onClipboardExpired(Map<String, dynamic> e) {
    final offerId = e['offerId']?.toString() ?? '';
    final eventId = e['eventId']?.toString();
    _add(LocalEvent(
      kind: LocalEventKind.clipboardExpired,
      title: 'Clipboard offer expired',
      subtitle: 'Offer ID: ${_shortId(offerId)}',
      time: DateTime.now(),
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'clipboard.expired',
        subject: offerId,
      ),
      reconciliationKey: _buildReconciliationKey('clipboard.expired', null),
      eventId: eventId,
    ));
  }

  void _onFileCompleted(Map<String, dynamic> e) {
    final fileName = e['fileName']?.toString() ?? 'file';
    final peerDeviceId = e['peerDeviceId']?.toString() ?? '';
    final eventId = e['eventId']?.toString();
    _add(LocalEvent(
      kind: LocalEventKind.fileReceived,
      title: 'File received',
      subtitle: fileName,
      time: DateTime.now(),
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'file_transfer.completed',
        peerDeviceId: peerDeviceId,
        subject: e['transferId']?.toString() ?? fileName,
      ),
      reconciliationKey: _buildReconciliationKey(
        'file_transfer.completed',
        peerDeviceId,
      ),
      eventId: eventId,
      peerDeviceId: peerDeviceId,
    ));
  }

  void _onFileFailed(Map<String, dynamic> e) {
    final fileName = e['fileName']?.toString() ?? 'file';
    final peerDeviceId = e['peerDeviceId']?.toString() ?? '';
    final eventId = e['eventId']?.toString();
    _add(LocalEvent(
      kind: LocalEventKind.fileFailed,
      title: 'File transfer failed',
      subtitle: fileName,
      time: DateTime.now(),
      identityKey: _buildIdentityKey(
        eventId: eventId,
        eventType: 'file_transfer.failed',
        peerDeviceId: peerDeviceId,
        subject: e['transferId']?.toString() ?? fileName,
      ),
      reconciliationKey: _buildReconciliationKey(
        'file_transfer.rejected',
        peerDeviceId,
      ),
      eventId: eventId,
      peerDeviceId: peerDeviceId,
    ));
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
