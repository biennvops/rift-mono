import 'dart:typed_data';
import 'package:test/test.dart';
import '../lib/src/interfaces/identity_manager.dart';

class MockIdentityManager implements IdentityManager {
  @override
  String get deviceId => 'mock-device-123';

  @override
  Future<void> initialize() async {}

  @override
  Uint8List getDeviceFingerprint() => Uint8List(0);

  @override
  Uint8List getEd25519PublicKey() => Uint8List(0);
}

void main() {
  group('Interfaces Tests', () {
    test('IdentityManager interface should be implementable', () {
      final manager = MockIdentityManager();
      expect(manager.deviceId, equals('mock-device-123'));
    });
  });
}
