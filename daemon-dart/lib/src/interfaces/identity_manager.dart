import 'dart:typed_data';

abstract class IdentityManager {
  Future<void> initialize();
  Uint8List getEd25519PublicKey();
  Uint8List getDeviceFingerprint();
  String get deviceId;
  String get displayName;
  Future<void> setDisplayName(String name);
  String get tlsCertificatePem;
  /// DER-encoded form of the local TLS certificate.
  /// Used by session_manager to bind PoP proofs to this device's own cert.
  Uint8List get tlsCertificateDer;
  String get tlsPrivateKeyPem;
  /// Signs a PoP proof over [localCertDer] (the SIGNER's own cert DER, not the peer's).
  Future<String> generateIdentityProof(Uint8List channelBinding, Uint8List localCertDer);
  Future<void> dispose();
}
