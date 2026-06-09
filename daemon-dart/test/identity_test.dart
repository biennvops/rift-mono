
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

    test('Should correctly sign Proof of Possession', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      await manager.initialize();

      var validChannelBinding = Uint8List.fromList(List.generate(32, (i) => i));
      var validCertDer = Uint8List.fromList([1, 2, 3]);

      // Should sign successfully
      var signatureHex = await manager.generateIdentityProof(validChannelBinding, validCertDer);
      expect(signatureHex.length, equals(128)); // Ed25519 signature hex string is 128 chars
    });

    test('Should throw StateError if signing before initialize', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      var validBuffer = Uint8List.fromList(List.generate(32, (i) => i));
      
      expect(
        () => manager.generateIdentityProof(validBuffer, validBuffer),
        throwsA(isA<StateError>()),
      );
    });

    test('Contract Stub: generateIdentityProof returns valid Future<String> signature asynchronously', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      await manager.initialize();
      var cb = Uint8List(32);
      // Use a recognisable fake DER stub (not all-zeros, which looks like a hash)
      var fakeCertDer = Uint8List.fromList([0x30, 0x03, 0x01, 0x01, 0x00]);
      
      // Verify it returns a Future correctly (async signature compliance)
      var signatureFuture = manager.generateIdentityProof(cb, fakeCertDer);
      expect(signatureFuture, isA<Future<String>>());
      
      var signatureHex = await signatureFuture;
      expect(signatureHex.length, equals(128));
    });

    test('Should clear memory on dispose', () async {
      var manager = IdentityManagerImpl(tempDir.path);
      await manager.initialize();
      await manager.dispose();
      
      var validBuffer = Uint8List.fromList(List.generate(32, (i) => i));
      expect(
        () => manager.generateIdentityProof(validBuffer, validBuffer),
        throwsA(isA<StateError>()),
      );
    });
  });
}
