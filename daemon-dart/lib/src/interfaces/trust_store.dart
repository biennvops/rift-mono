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

class TrustRecord {
  final String deviceId;
  final Uint8List ed25519PublicKey;
  final String fingerprint;
  final TrustState state;
  final DateTime? lastSeenAt;

  TrustRecord({
    required this.deviceId,
    required this.ed25519PublicKey,
    required this.fingerprint,
    required this.state,
    this.lastSeenAt,
  });
}

abstract class TrustStore {
  Future<void> initialize();
  Future<void> saveTrustRecord(TrustRecord record);
  Future<TrustRecord?> getTrustRecord(String deviceId);
  Future<List<TrustRecord>> getAllTrustRecords();
  Future<TrustState> getTrustState(String deviceId);
  Future<void> blockDevice(String deviceId);
  Future<void> revokeDevice(String deviceId, {required String reason});
  Future<void> unblockDevice(String deviceId);
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt);
}
