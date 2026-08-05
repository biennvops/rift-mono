import 'dart:typed_data';

import 'package:app_flutter/src/ipc/android_native_peer_transport.dart';
import 'package:app_flutter/src/ipc/native_tls_api.dart';
import 'package:app_flutter/src/platform/android_native_tls.dart';
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
  Future<String> generateIdentityProof(
    Uint8List channelBinding,
    Uint8List localCertDer,
  ) async =>
      '';
}

class _RecordingNativeTlsApi implements NativeTlsApi {
  int concurrentWrites = 0;
  int maxConcurrentWrites = 0;
  final List<int> writtenConnectionIds = [];

  @override
  Future<void> write(int connectionId, String dataBase64) async {
    concurrentWrites += 1;
    if (concurrentWrites > maxConcurrentWrites) {
      maxConcurrentWrites = concurrentWrites;
    }
    writtenConnectionIds.add(connectionId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    concurrentWrites -= 1;
  }

  @override
  Future<AndroidTlsConnection> accept() => throw UnimplementedError();

  @override
  Future<void> close(int connectionId) async {}

  @override
  Future<AndroidTlsConnection> connect({
    required String host,
    required int port,
    required String certificatePem,
    required String privateKeyPem,
  }) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> read(int connectionId) =>
      throw UnimplementedError();

  @override
  Future<int> startServer({
    required String certificatePem,
    required String privateKeyPem,
    int port = 0,
  }) async =>
      port;

  @override
  Future<void> stopServer() async {}
}

void main() {
  group('AndroidNativePeerTransport duplicate connection ownership', () {
    test('resets the old session synchronously before replacement teardown',
        () {
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
      );
      String? disconnectedPeer;
      transport.onPeerDisconnected.listen((peerDeviceId) {
        disconnectedPeer = peerDeviceId;
      });

      transport.resetSessionForReplacement('rift-peer');

      expect(disconnectedPeer, 'rift-peer');
    });

    test('serializes concurrent writes for one peer', () async {
      final tls = _RecordingNativeTlsApi();
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
      );

      await Future.wait([
        transport.sendMessage('rift-peer', Uint8List.fromList([123, 125])),
        transport.sendMessage('rift-peer', Uint8List.fromList([123, 125])),
      ]);

      expect(tls.maxConcurrentWrites, 1);
      expect(tls.writtenConnectionIds, [42, 42]);
      await transport.stopServer();
    });

    test('retains an existing preferred connection', () {
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: true,
          candidateIsServer: false,
          preferredIsServer: true,
        ),
        isTrue,
      );
    });

    test('replaces an existing non-preferred connection', () {
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: false,
          candidateIsServer: true,
          preferredIsServer: true,
        ),
        isFalse,
      );
    });

    test('retains the first connection when both have the same role', () {
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: false,
          candidateIsServer: false,
          preferredIsServer: true,
        ),
        isTrue,
      );
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: true,
          candidateIsServer: true,
          preferredIsServer: true,
        ),
        isTrue,
      );
    });
  });
}
