import 'dart:typed_data';

enum TrustState {
  discovered,
  pairingPending,
  trusted,
  blocked,
  revoked,
}

class TrustRecord {
  final String deviceId;
  final Uint8List ed25519PublicKey;
  final String fingerprint;
  final TrustState state;

  TrustRecord({
    required this.deviceId,
    required this.ed25519PublicKey,
    required this.fingerprint,
    required this.state,
  });
}

abstract class TrustStore {
  Future<void> initialize();
  Future<void> saveTrustRecord(TrustRecord record);
  Future<TrustRecord?> getTrustRecord(String deviceId);
  Future<TrustState> getTrustState(String deviceId);
  Future<void> blockDevice(String deviceId);
  Future<void> revokeDevice(String deviceId, {required String reason});
  Future<void> unblockDevice(String deviceId);
}
