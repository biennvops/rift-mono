import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/crypto/pop_manager.dart';
import 'package:test/test.dart';
import 'package:cryptography/cryptography.dart';

void main() {
  group('PoPManager Tests', () {
    test('buildSigningInput constructs exact 113-byte payload with length prefixes', () {
      final channelBinding = Uint8List.fromList(List.generate(32, (i) => i));
      final pubKey = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final certDer = Uint8List.fromList([1, 2, 3, 4, 5]); // Fake cert
      final certHash = Uint8List.fromList(sha256.convert(certDer).bytes);

      final input = PoPManager.buildSigningInput(channelBinding, pubKey, certDer);

      expect(input.length, equals(113));
      
      final prefix = utf8.encode('RiftPoP-v2:');
      expect(input.sublist(0, 11), equals(prefix));
      
      expect(input.sublist(11, 13), equals([0, 32])); // channelBinding length
      expect(input.sublist(13, 45), equals(channelBinding));
      
      expect(input.sublist(45, 47), equals([0, 32])); // pubKey length
      expect(input.sublist(47, 79), equals(pubKey));
      
      expect(input.sublist(79, 81), equals([0, 32])); // certHash length
      expect(input.sublist(81, 113), equals(certHash));
    });

    test('generateIdentityProof and verifyIdentityProof succeed symmetrically', () async {
      final channelBinding = Uint8List.fromList(List.generate(32, (i) => 42));
      final certDer = Uint8List.fromList([10, 20, 30]);

      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
      final publicKeyBytes = (await keyPair.extractPublicKey()).bytes;

      final proofHex = await PoPManager.generateIdentityProof(
          channelBinding, Uint8List.fromList(publicKeyBytes), certDer, Uint8List.fromList(privateKeyBytes));
      
      expect(proofHex.length, equals(128));

      final isValid = await PoPManager.verifyIdentityProof(
          proofHex, channelBinding, Uint8List.fromList(publicKeyBytes), certDer);
      expect(isValid, isTrue);
    });

    test('verifyIdentityProof fails if any part of the input changes', () async {
      final channelBinding = Uint8List.fromList(List.generate(32, (i) => 42));
      final certDer = Uint8List.fromList([10, 20, 30]);

      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
      final publicKeyBytes = (await keyPair.extractPublicKey()).bytes;
      final pubKeyList = Uint8List.fromList(publicKeyBytes);

      final proofHex = await PoPManager.generateIdentityProof(
          channelBinding, pubKeyList, certDer, Uint8List.fromList(privateKeyBytes));

      // Wrong channel binding
      final wrongCb = Uint8List.fromList(channelBinding);
      wrongCb[0] = 99;
      expect(await PoPManager.verifyIdentityProof(proofHex, wrongCb, pubKeyList, certDer), isFalse);

      // Wrong pub key
      final wrongPk = Uint8List.fromList(publicKeyBytes);
      wrongPk[0] ^= 1;
      expect(await PoPManager.verifyIdentityProof(proofHex, channelBinding, wrongPk, certDer), isFalse);

      // Wrong cert
      final wrongCert = Uint8List.fromList([10, 20, 31]);
      expect(await PoPManager.verifyIdentityProof(proofHex, channelBinding, pubKeyList, wrongCert), isFalse);
    });

    test('verifyIdentityProof fails on malformed hex without throwing', () async {
      final channelBinding = Uint8List.fromList(List.generate(32, (i) => 42));
      final pubKey = Uint8List.fromList(List.generate(32, (i) => i));
      final certDer = Uint8List.fromList([10, 20, 30]);

      final malformedHex = '${'0' * 126}zz';
      final isValid = await PoPManager.verifyIdentityProof(
        malformedHex,
        channelBinding,
        pubKey,
        certDer,
      );

      expect(isValid, isFalse);
    });
  });
}
