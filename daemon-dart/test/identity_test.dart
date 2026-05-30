// test/identity_test.dart

import 'dart:io';

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
  });
}
