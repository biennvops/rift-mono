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
  final List<TrustedPeerEndpoint> trustedEndpoints;

  PeerRecord({
    required this.deviceId,
    this.displayName,
    required this.certDer,
    required this.state,
    this.pairedAt,
    required this.updatedAt,
    this.lastSeenAt,
    this.trustedEndpoints = const [],
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
      trustedEndpoints: trustedEndpoints
          .map((endpoint) => endpoint.copy())
          .toList(growable: false),
    );
  }
}

class TrustedPeerEndpoint {
  final String address;
  final int port;
  final String source;
  final String? addressFamily;
  final DateTime lastSuccessAt;

  const TrustedPeerEndpoint({
    required this.address,
    required this.port,
    required this.source,
    this.addressFamily,
    required this.lastSuccessAt,
  });

  TrustedPeerEndpoint copy() {
    return TrustedPeerEndpoint(
      address: address,
      port: port,
      source: source,
      addressFamily: addressFamily,
      lastSuccessAt: lastSuccessAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'address': address,
      'port': port,
      'source': source,
      if (addressFamily != null) 'addressFamily': addressFamily,
      'lastSuccessAt': lastSuccessAt.toUtc().toIso8601String(),
    };
  }

  factory TrustedPeerEndpoint.fromJson(Map<String, dynamic> json) {
    final address = json['address'];
    final port = json['port'];
    final source = json['source'];
    final lastSuccessAt = json['lastSuccessAt'];

    if (address is! String || address.isEmpty) {
      throw const FormatException('TrustedPeerEndpoint.address is required');
    }
    if (port is! int || port <= 0 || port > 65535) {
      throw const FormatException('TrustedPeerEndpoint.port must be 1..65535');
    }
    if (source is! String || source.isEmpty) {
      throw const FormatException('TrustedPeerEndpoint.source is required');
    }
    if (lastSuccessAt is! String) {
      throw const FormatException(
        'TrustedPeerEndpoint.lastSuccessAt is required',
      );
    }

    final parsedLastSuccessAt = DateTime.tryParse(lastSuccessAt)?.toUtc();
    if (parsedLastSuccessAt == null) {
      throw const FormatException(
        'TrustedPeerEndpoint.lastSuccessAt must be RFC3339',
      );
    }

    final addressFamily = json['addressFamily'];
    if (addressFamily != null && addressFamily is! String) {
      throw const FormatException(
        'TrustedPeerEndpoint.addressFamily must be a string',
      );
    }

    return TrustedPeerEndpoint(
      address: address,
      port: port,
      source: source,
      addressFamily: addressFamily as String?,
      lastSuccessAt: parsedLastSuccessAt,
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
  Future<List<PeerRecord>> getAllPeers();
  Future<bool> transitionState(String deviceId, TrustState from, TrustState to, {DateTime? pairedAt});
  Future<void> deletePeer(String deviceId);
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt);
  Future<void> updateDisplayName(String deviceId, String displayName);
  Future<void> appendSecurityEvent(SecurityEventRecord record);
  Future<List<SecurityEventRecord>> querySecurityEvents(SecurityEventQuery query);
  Future<int> countSecurityEvents(SecurityEventQuery query);
}
