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
  notificationFromPeer,
  mediaPlayingOnPeer,
  mediaStoppedOnPeer,
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
  final List<StreamSubscription<dynamic>> _subs = [];

  LocalEventsNotifier(this._client) {
    _subs.addAll([
      _client.onTrustChanged.listen(_onTrustChanged),
      _client.onPairingRequest.listen(_onPairingRequest),
      _client.onClipboardOffer.listen(_onClipboardOffer),
      _client.onClipboardExpired.listen(_onClipboardExpired),
      _client.onFileTransferCompleted.listen(_onFileCompleted),
      _client.onFileTransferFailed.listen(_onFileFailed),
      _client.onNotificationPosted.listen(_onNotificationPosted),
      _client.onMediaPlaybackPosted.listen(_onMediaPosted),
      _client.onMediaPlaybackRemoved.listen(_onMediaRemoved),
    ]);
  }

  List<LocalEvent> get events => List.unmodifiable(_events);
  int get unreadCount => _unreadCount;
  int _unreadCount = 0;

  void markAllRead() {
    _unreadCount = 0;
    notifyListeners();
  }

  void _add(LocalEvent event) {
    _events.insert(0, event);
    if (_events.length > _maxEvents) _events.removeLast();
    _unreadCount++;
    notifyListeners();
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

  void _onNotificationPosted(Map<String, dynamic> e) {
    final deviceId = e['sourceDeviceId']?.toString() ?? '';
    final appName = e['appName']?.toString() ?? 'App';
    _add(LocalEvent(
      kind: LocalEventKind.notificationFromPeer,
      title: '${_shortId(deviceId)}: $appName',
      subtitle: e['title']?.toString() ??
          e['bodyPreview']?.toString() ??
          'New notification',
      time: DateTime.now(),
      peerDeviceId: deviceId,
    ));
  }

  void _onMediaPosted(Map<String, dynamic> e) {
    final deviceId = e['sourceDeviceId']?.toString() ?? '';
    final title = e['title']?.toString() ?? 'media';
    _add(LocalEvent(
      kind: LocalEventKind.mediaPlayingOnPeer,
      title: 'Playing on ${_shortId(deviceId)}',
      subtitle: title,
      time: DateTime.now(),
      peerDeviceId: deviceId,
    ));
  }

  void _onMediaRemoved(Map<String, dynamic> e) {
    final deviceId = e['sourceDeviceId']?.toString() ?? '';
    _add(LocalEvent(
      kind: LocalEventKind.mediaStoppedOnPeer,
      title: 'Media stopped on ${_shortId(deviceId)}',
      subtitle: '',
      time: DateTime.now(),
      peerDeviceId: deviceId,
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
