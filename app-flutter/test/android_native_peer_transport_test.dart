import 'dart:typed_data';

import 'package:app_flutter/src/ipc/android_native_peer_transport.dart';
import 'package:daemon_dart/daemon_dart.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<void> setDisplayName(String name) async {}

  @override
  Future<String> generateIdentityProof(
    Uint8List channelBinding,
    Uint8List localCertDer,
  ) async =>
      '';
}

void main() {
  test('pre-auth native replacement resets the session synchronously', () {
    final transport = AndroidNativePeerTransport(
      _FakeIdentityManager(),
      port: 0,
    );
    String? disconnectedPeer;
    transport.onPeerDisconnected.listen((peerDeviceId) {
      disconnectedPeer = peerDeviceId;
    });

    transport.resetSessionForPreAuthReplacement('rift-peer');

    expect(disconnectedPeer, 'rift-peer');
  });
}
