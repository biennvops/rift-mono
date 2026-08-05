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
    this.peerDeviceId,
  });

  final LocalEventKind kind;
  final String title;
  final String subtitle;
  final DateTime time;
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
      _client.onClipboardOffer.listen(_onClipboardOffer),
      _client.onClipboardExpired.listen(_onClipboardExpired),
      _client.onFileTransferCompleted.listen(_onFileCompleted),
      _client.onFileTransferFailed.listen(_onFileFailed),
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
      _events.removeWhere(_historyEvents.contains);
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
    final peerDeviceId = record['peerDeviceId']?.toString();
    final peer = _shortId(peerDeviceId ?? '');
    final time =
        DateTime.tryParse(record['timestamp']?.toString() ?? '')?.toLocal() ??
            DateTime.now();

    return switch (type) {
      'connection.established' => LocalEvent(
          kind: LocalEventKind.deviceConnected,
          title: 'Device connected',
          subtitle: peer,
          time: time,
          peerDeviceId: peerDeviceId,
        ),
      'connection.lost' => LocalEvent(
          kind: LocalEventKind.deviceDisconnected,
          title: 'Device disconnected',
          subtitle: peer,
          time: time,
          peerDeviceId: peerDeviceId,
        ),
      'trust.transitioned' => LocalEvent(
          kind: LocalEventKind.deviceTrusted,
          title: 'Trust updated',
          subtitle: peer,
          time: time,
          peerDeviceId: peerDeviceId,
        ),
      'pairing.attempted' => LocalEvent(
          kind: LocalEventKind.devicePairingRequest,
          title: 'Pairing activity',
          subtitle: peer,
          time: time,
          peerDeviceId: peerDeviceId,
        ),
      'clipboard.offered' => LocalEvent(
          kind: LocalEventKind.clipboardReceived,
          title: 'Clipboard received',
          subtitle: peer.isEmpty ? 'Incoming clipboard offer' : 'From $peer',
          time: time,
          peerDeviceId: peerDeviceId,
        ),
      'clipboard.expired' => LocalEvent(
          kind: LocalEventKind.clipboardExpired,
          title: 'Clipboard offer expired',
          subtitle: peer,
          time: time,
          peerDeviceId: peerDeviceId,
        ),
      'file_transfer.rejected' => LocalEvent(
          kind: LocalEventKind.fileFailed,
          title: 'File transfer rejected',
          subtitle: peer,
          time: time,
          peerDeviceId: peerDeviceId,
        ),
      _ => null,
    };
  }

  void _onTrustChanged(Map<String, dynamic> e) {
    final deviceId = e['deviceId']?.toString() ?? '';
    final newState = e['newState']?.toString() ?? '';
    final name = e['displayName']?.toString() ?? _shortId(deviceId);

    switch (newState) {
      case 'trusted':
        _add(LocalEvent(
          kind: LocalEventKind.deviceTrusted,
          title: 'Device trusted',
          subtitle: name,
          time: DateTime.now(),
          peerDeviceId: deviceId,
        ));
      case 'discovered':
        _add(LocalEvent(
          kind: LocalEventKind.deviceConnected,
          title: 'Device discovered',
          subtitle: name,
          time: DateTime.now(),
          peerDeviceId: deviceId,
        ));
      case 'blocked':
        _add(LocalEvent(
          kind: LocalEventKind.deviceDisconnected,
          title: 'Device blocked',
          subtitle: name,
          time: DateTime.now(),
          peerDeviceId: deviceId,
        ));
    }
  }

  void _onPairingRequest(Map<String, dynamic> e) {
    final deviceId = e['deviceId']?.toString() ?? '';
    final name = e['displayName']?.toString() ?? _shortId(deviceId);
    _add(LocalEvent(
      kind: LocalEventKind.devicePairingRequest,
      title: 'Pairing request',
      subtitle: name,
      time: DateTime.now(),
      peerDeviceId: deviceId,
    ));
  }

  void _onClipboardOffer(Map<String, dynamic> e) {
    final deviceId = e['sourceDeviceId']?.toString() ?? '';
    final contentType = e['contentType']?.toString() ?? 'content';
    final label = contentType.startsWith('text/') ? 'Text' : 'File';
    _add(LocalEvent(
      kind: LocalEventKind.clipboardReceived,
      title: 'Clipboard received',
      subtitle: '$label from ${_shortId(deviceId)}',
      time: DateTime.now(),
      peerDeviceId: deviceId,
    ));
  }

  void _onClipboardExpired(Map<String, dynamic> e) {
    _add(LocalEvent(
      kind: LocalEventKind.clipboardExpired,
      title: 'Clipboard offer expired',
      subtitle: 'Offer ID: ${_shortId(e['offerId']?.toString() ?? '')}',
      time: DateTime.now(),
    ));
  }

  void _onFileCompleted(Map<String, dynamic> e) {
    final fileName = e['fileName']?.toString() ?? 'file';
    final peerDeviceId = e['peerDeviceId']?.toString() ?? '';
    _add(LocalEvent(
      kind: LocalEventKind.fileReceived,
      title: 'File received',
      subtitle: fileName,
      time: DateTime.now(),
      peerDeviceId: peerDeviceId,
    ));
  }

  void _onFileFailed(Map<String, dynamic> e) {
    final fileName = e['fileName']?.toString() ?? 'file';
    _add(LocalEvent(
      kind: LocalEventKind.fileFailed,
      title: 'File transfer failed',
      subtitle: fileName,
      time: DateTime.now(),
    ));
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
