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

abstract class TrustStore {
  Future<void> initialize();
  Future<void> upsertPeer(PeerRecord record);
  Future<PeerRecord?> getPeer(String deviceId);
  Future<List<PeerRecord>> getPeersByState(TrustState state);
  Future<bool> transitionState(String deviceId, TrustState from, TrustState to, {DateTime? pairedAt});
  Future<void> deletePeer(String deviceId);
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt);
}
