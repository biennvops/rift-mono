import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class PoPException implements Exception {
  final String message;
  PoPException(this.message);
  @override
  String toString() => 'PoPException: $message';
}

/// Handles Ed25519 Proof of Possession (PoP) construction and verification
/// as defined in Rift Protocol Specification Section 5.3.
class PoPManager {
  static const String popPrefix = 'RiftPoP-v2:';

  // Signing input breakdown (Spec §5.3.1):
  //   prefix                        : 11 bytes  ('RiftPoP-v2:')
  //   [len(2)] + channelBinding     : 2 + 32 = 34 bytes
  //   [len(2)] + ed25519PublicKey   : 2 + 32 = 34 bytes
  //   [len(2)] + sha256(certDer)    : 2 + 32 = 34 bytes
  //   Total                         : 11 + 34 + 34 + 34 = 113 bytes
  static const int _expectedSigningInputLength = 113;

  /// Constructs the PoP signing input exactly as per Spec Section 5.3.1
  static Uint8List buildSigningInput(
      Uint8List channelBinding, Uint8List ed25519PublicKey, Uint8List certDer) {
    if (channelBinding.length != 32) {
      throw PoPException('Channel binding must be exactly 32 bytes');
    }
    if (ed25519PublicKey.length != 32) {
      throw PoPException('Ed25519 public key must be exactly 32 bytes');
    }

    final certHash = Uint8List.fromList(sha256.convert(certDer).bytes);

    final prefixBytes = utf8.encode(popPrefix);
    final input = BytesBuilder(copy: false);
    input.add(prefixBytes);
    
    // Mitigating Canonicalization Attack: 2-byte length prefix for each dynamic field
    input.add([channelBinding.length >> 8, channelBinding.length & 0xFF]);
    input.add(channelBinding);
    
    input.add([ed25519PublicKey.length >> 8, ed25519PublicKey.length & 0xFF]);
    input.add(ed25519PublicKey);
    
    input.add([certHash.length >> 8, certHash.length & 0xFF]);
    input.add(certHash);

    final result = input.takeBytes();
    if (result.length != _expectedSigningInputLength) {
      throw PoPException('Signing input length mismatch. Expected $_expectedSigningInputLength, got ${result.length}');
    }
    return result;
  }

  /// Signs the PoP input using the local Ed25519 private key
  static Future<String> generateIdentityProof(
      Uint8List channelBinding, Uint8List ed25519PublicKey, Uint8List certDer, Uint8List ed25519PrivateKey) async {
    final input = buildSigningInput(channelBinding, ed25519PublicKey, certDer);

    final algorithm = Ed25519();
    final keyPair = SimpleKeyPairData(
      ed25519PrivateKey,
      publicKey: SimplePublicKey(ed25519PublicKey, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );

    final signature = await algorithm.sign(input, keyPair: keyPair);
    
    // Encode the 64-byte signature to 128-character lowercase hex string
    return signature.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toLowerCase();
  }

  /// Verifies a peer's identity proof from session.hello
  static Future<bool> verifyIdentityProof(
      String identityProofHex, Uint8List channelBinding, Uint8List peerEd25519PublicKey, Uint8List peerCertDer) async {
    if (identityProofHex.length != 128) {
      return false;
    }

    final signatureBytes = Uint8List(64);
    for (int i = 0; i < 64; i++) {
      final byteStr = identityProofHex.substring(i * 2, i * 2 + 2);
      signatureBytes[i] = int.parse(byteStr, radix: 16);
    }

    final input = buildSigningInput(channelBinding, peerEd25519PublicKey, peerCertDer);
    final algorithm = Ed25519();
    final pubKey = SimplePublicKey(peerEd25519PublicKey, type: KeyPairType.ed25519);
    final signature = Signature(signatureBytes, publicKey: pubKey);

    try {
      return await algorithm.verify(input, signature: signature);
    } catch (_) {
      return false;
    }
  }
}
