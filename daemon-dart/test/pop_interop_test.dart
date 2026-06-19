import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/crypto/pop_manager.dart';
import 'package:test/test.dart';

Uint8List hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

void main() {
  group('PoP Interop Vector (spec/vectors/vectors.json popInterop)', () {
    // Deterministic test inputs from the shared vector file.
    final signerNonce = hexToBytes(
        '0101010101010101010101010101010101010101010101010101010101010101');
    final signerCertDer = hexToBytes('aabbccdd');
    final verifierCertDer = hexToBytes('eeff0011');
    final ed25519PubKey = hexToBytes(
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3');

    final expectedChannelBindingHex =
        'c27ec22512ef4f08cbb55cca019d1eb26d09ad24efeaff2626e56f6cb3afca36';
    final expectedCertHashHex =
        '8d70d691c822d55638b6e7fd54cd94170c87d19eb1f628b757506ede5688d297';
    final expectedSigningInputHex =
        '52696674506f502d76323ac27ec22512ef4f08cbb55cca019d1eb26d09ad24efeaff2626e56f6cb3afca36d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e38d70d691c822d55638b6e7fd54cd94170c87d19eb1f628b757506ede5688d297';

    test('app-nonce channel binding matches vector', () {
      final cbInput = Uint8List(
          signerNonce.length + signerCertDer.length + verifierCertDer.length);
      cbInput.setRange(0, signerNonce.length, signerNonce);
      cbInput.setRange(signerNonce.length,
          signerNonce.length + signerCertDer.length, signerCertDer);
      cbInput.setRange(
          signerNonce.length + signerCertDer.length, cbInput.length,
          verifierCertDer);
      final channelBinding =
          Uint8List.fromList(sha256.convert(cbInput).bytes);

      final hex = channelBinding
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(hex, equals(expectedChannelBindingHex));
    });

    test('cert hash matches vector', () {
      final certHash =
          Uint8List.fromList(sha256.convert(signerCertDer).bytes);
      final hex = certHash
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(hex, equals(expectedCertHashHex));
    });

    test('signing input matches vector (107 bytes, raw concatenation)', () {
      final cbInput = Uint8List(
          signerNonce.length + signerCertDer.length + verifierCertDer.length);
      cbInput.setRange(0, signerNonce.length, signerNonce);
      cbInput.setRange(signerNonce.length,
          signerNonce.length + signerCertDer.length, signerCertDer);
      cbInput.setRange(
          signerNonce.length + signerCertDer.length, cbInput.length,
          verifierCertDer);
      final channelBinding =
          Uint8List.fromList(sha256.convert(cbInput).bytes);

      final signingInput = PoPManager.buildSigningInput(
          channelBinding, ed25519PubKey, signerCertDer);

      expect(signingInput.length, equals(107));

      final hex = signingInput
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(hex, equals(expectedSigningInputHex));
    });
  });
}
