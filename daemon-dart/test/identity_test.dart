
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';

void main() {
  group('IdentityManagerImpl Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('rift_identity_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('Should generate a new identity if none exists', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      await manager.initialize();
      
      expect(manager.getEd25519PublicKey().length, equals(32));
      expect(manager.getDeviceFingerprint().length, equals(32)); // SHA-256 output
      expect(manager.deviceId.startsWith('rift-'), isTrue);
      expect(manager.deviceId.length, equals(5 + 32)); // 'rift-' + 32 chars
    });

    test('Should load existing identity from disk', () async {
      var manager1 = IdentityManagerImpl(tempDir.path);
      await manager1.initialize();
      var key1 = manager1.getEd25519PublicKey();
      var deviceId1 = manager1.deviceId;

      // Create a second manager pointing to the same dir
      var manager2 = IdentityManagerImpl(tempDir.path);
      await manager2.initialize();
      var key2 = manager2.getEd25519PublicKey();
      var deviceId2 = manager2.deviceId;

      expect(key2, equals(key1));
      expect(deviceId2, equals(deviceId1));
    });

    test('Should throw Exception if key file is corrupted (wrong length)', () async {
      var keyFile = File('${tempDir.path}/identity.key');
      await keyFile.writeAsBytes([1, 2, 3]); // Only 3 bytes instead of 32
      
      var manager = IdentityManagerImpl(tempDir.path);
      expect(
        () => manager.initialize(),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('Corrupted identity key file'))),
      );
    });

    test('Should correctly sign Proof of Possession and enforce 32-byte arguments', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      await manager.initialize();

      var validChannelBinding = Uint8List.fromList(List.generate(32, (i) => i));
      var validCertHash = Uint8List.fromList(List.generate(32, (i) => 255 - i));

      // Should sign successfully
      var signature = await manager.signIdentityProof(validChannelBinding, validCertHash);
      expect(signature.length, equals(64)); // Ed25519 signature is 64 bytes

      // Should throw on invalid length
      var invalidBuffer = Uint8List.fromList(List.generate(31, (i) => i));
      expect(
        () => manager.signIdentityProof(invalidBuffer, validCertHash),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => manager.signIdentityProof(validChannelBinding, invalidBuffer),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('Should throw StateError if signing before initialize', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      var validBuffer = Uint8List.fromList(List.generate(32, (i) => i));
      
      expect(
        () => manager.signIdentityProof(validBuffer, validBuffer),
        throwsA(isA<StateError>()),
      );
    });

    test('Contract Stub: signIdentityProof returns valid Future<Uint8List> signature asynchronously', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      await manager.initialize();
      var cb = Uint8List(32);
      var ch = Uint8List(32);
      
      // Verify it returns a Future correctly (async signature compliance)
      var signatureFuture = manager.signIdentityProof(cb, ch);
      expect(signatureFuture, isA<Future<Uint8List>>());
      
      var signature = await signatureFuture;
      expect(signature.length, equals(64));
    });

    test('Should clear memory on dispose', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      await manager.initialize();
      await manager.dispose();
      
      var validBuffer = Uint8List.fromList(List.generate(32, (i) => i));
      expect(
        () => manager.signIdentityProof(validBuffer, validBuffer),
        throwsA(isA<StateError>()),
      );
    });
  });
}
