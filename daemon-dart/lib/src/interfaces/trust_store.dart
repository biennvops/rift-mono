import 'dart:typed_data';

enum TrustState {
  discovered,
  pairingPending,
  trusted,
  blocked,
  revoked;

  String toJson() {
    if (this == TrustState.pairingPending) return 'pairing_pending';
    return name;
  }

  static TrustState fromJson(String value) {
    if (value == 'pairing_pending') return TrustState.pairingPending;
    return TrustState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => throw ArgumentError('Unknown TrustState: $value'),
    );
  }
}

class PeerRecord {
  final String deviceId;
  final String? displayName;
  final Uint8List certDer;
  final TrustState state;
  final DateTime? pairedAt;
  final DateTime updatedAt;
  final DateTime? lastSeenAt;

  PeerRecord({
    required this.deviceId,
    this.displayName,
    required this.certDer,
    required this.state,
    this.pairedAt,
    required this.updatedAt,
    this.lastSeenAt,
  });

  /// Creates a defensive copy of this PeerRecord to prevent mutation of internal state,
  /// especially the certDer Uint8List.
  PeerRecord copy() {
    return PeerRecord(
      deviceId: deviceId,
      displayName: displayName,
      certDer: Uint8List.fromList(certDer),
      state: state,
      pairedAt: pairedAt,
      updatedAt: updatedAt,
      lastSeenAt: lastSeenAt,
    );
  }
}

class SecurityEventRecord {
  final String eventId;
  final String eventType;
  final String severity;
  final String localDeviceId;
  final DateTime timestamp;
  final String outcome;
  final String? peerDeviceId;
  final String? failureReason;
  final Map<String, dynamic>? details;

  SecurityEventRecord({
    required this.eventId,
    required this.eventType,
    required this.severity,
    required this.localDeviceId,
    required this.timestamp,
    required this.outcome,
    this.peerDeviceId,
    this.failureReason,
    this.details,
  });

  Map<String, dynamic> toJson() {
    return {
      'eventId': eventId,
      'eventType': eventType,
      'severity': severity,
      'localDeviceId': localDeviceId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'outcome': outcome,
      if (peerDeviceId != null && peerDeviceId!.isNotEmpty)
        'peerDeviceId': peerDeviceId,
      if (failureReason != null && failureReason!.isNotEmpty)
        'failureReason': failureReason,
      if (details != null && details!.isNotEmpty) 'details': details,
    };
  }
}

class SecurityEventQuery {
  final List<String>? eventTypes;
  final List<String>? severities;
  final String? peerDeviceId;
  final DateTime? since;
  final int limit;
  final int offset;

  const SecurityEventQuery({
    this.eventTypes,
    this.severities,
    this.peerDeviceId,
    this.since,
    this.limit = 100,
    this.offset = 0,
  });
}

abstract class TrustStore {
  Future<void> initialize();
  Future<void> upsertPeer(PeerRecord record);
  Future<PeerRecord?> getPeer(String deviceId);
  Future<List<PeerRecord>> getPeersByState(TrustState state);
  Future<bool> transitionState(String deviceId, TrustState from, TrustState to, {DateTime? pairedAt});
  Future<void> deletePeer(String deviceId);
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt);
  Future<void> appendSecurityEvent(SecurityEventRecord record);
  Future<List<SecurityEventRecord>> querySecurityEvents(SecurityEventQuery query);
  Future<int> countSecurityEvents(SecurityEventQuery query);
}
