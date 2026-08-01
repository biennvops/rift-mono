import 'dart:typed_data';

import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/network/transport_impl.dart';
import 'package:test/test.dart';

class _FakeIdentityManager implements IdentityManager {
  @override
  String get deviceId => 'rift-local';

  @override
  String get displayName => 'Local device';

  @override
  Uint8List getDeviceFingerprint() => Uint8List(32);

  @override
  Uint8List getEd25519PublicKey() => Uint8List(32);

  @override
  String get tlsCertificatePem => '';

  @override
  Uint8List get tlsCertificateDer => Uint8List(0);

  @override
  String get tlsPrivateKeyPem => '';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> setDisplayName(String displayName) async {}

  @override
  Future<String> generateIdentityProof(
    Uint8List challenge,
    Uint8List binding,
  ) async => '';
}

void main() {
  test('disconnect is observed before a replacement socket can bootstrap', () {
    final transport = TransportImpl(_FakeIdentityManager(), port: 0);
    var disconnected = false;
    transport.onPeerDisconnected.listen((_) {
      disconnected = true;
    });

    transport.disconnect('rift-peer');

    expect(disconnected, isTrue);
  });
}
