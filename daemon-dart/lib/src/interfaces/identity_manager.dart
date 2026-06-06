import 'dart:typed_data';

abstract class IdentityManager {
  Future<void> initialize();
  Uint8List getEd25519PublicKey();
  Uint8List getDeviceFingerprint();
  String get deviceId;
  Future<Uint8List> signIdentityProof(Uint8List channelBinding, Uint8List certHash);
}
