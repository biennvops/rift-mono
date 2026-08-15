import 'dart:async';
import 'dart:typed_data';

import 'package:rift/src/ipc/android_native_peer_transport.dart';
import 'package:rift/src/ipc/native_tls_api.dart';
import 'package:rift/src/platform/android_native_tls.dart';
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
  final List<int> closedConnectionIds = [];

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
  Future<void> close(int connectionId) async {
    closedConnectionIds.add(connectionId);
  }

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
    test('pending candidate keeps the pre-authentication frame limit',
        () async {
      final tls = _RecordingNativeTlsApi();
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
        authenticated: true,
      );
      transport.injectPendingCandidateForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 43,
      );

      expect(
        transport.frameSizeLimitForTesting(42),
        RiftFrameCodec.maxFrameSizePostAuth,
      );
      expect(
        transport.frameSizeLimitForTesting(43),
        RiftFrameCodec.maxFrameSizePreAuth,
      );
      await transport.stopServer();
    });

    test('closes and notifies before blocked stream teardown', () async {
      final tls = _RecordingNativeTlsApi();
      final cancellation = Completer<void>();
      final frameController = StreamController<Map<String, dynamic>>(
        onCancel: () => cancellation.future,
      );
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
        frameSubscription: frameController.stream.listen((_) {}),
      );
      final disconnected = transport.onPeerDisconnected.first;

      transport.disconnect('rift-peer');
      await Future<void>.delayed(Duration.zero);

      expect(tls.closedConnectionIds, [42]);
      await expectLater(disconnected, completion('rift-peer'));
      cancellation.complete();
      await Future<void>.delayed(Duration.zero);
      await transport.stopServer();
    });

    test('replacement close does not await blocked stream teardown', () async {
      final tls = _RecordingNativeTlsApi();
      final cancellation = Completer<void>();
      final frameController = StreamController<Map<String, dynamic>>(
        onCancel: () => cancellation.future,
      );
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
        frameSubscription: frameController.stream.listen((_) {}),
      );

      await transport
          .closeConnectionForReplacementForTesting('rift-peer')
          .timeout(const Duration(milliseconds: 100));

      expect(tls.closedConnectionIds, [42]);
      cancellation.complete();
      await Future<void>.delayed(Duration.zero);
      await transport.stopServer();
    });

    test('candidate teardown preserves the established connection', () async {
      final tls = _RecordingNativeTlsApi();
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      final disconnects = <String>[];
      final disconnectSub =
          transport.onPeerDisconnected.listen(disconnects.add);
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
      );
      transport.injectPendingCandidateForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 43,
      );

      await transport.closePendingCandidateForTesting('rift-peer');
      await transport.sendMessage('rift-peer', Uint8List.fromList([123, 125]));

      expect(tls.closedConnectionIds, [43]);
      expect(tls.writtenConnectionIds, [42]);
      expect(disconnects, isEmpty);
      await disconnectSub.cancel();
      await transport.stopServer();
    });

    test('syntactic candidate hello does not evict the authenticated session',
        () async {
      final tls = _RecordingNativeTlsApi();
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      final disconnects = <String>[];
      final disconnectSub =
          transport.onPeerDisconnected.listen(disconnects.add);
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
        authenticated: true,
      );
      transport.injectPendingCandidateForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 43,
      );
      final candidateMessage = transport.onMessageReceived.first;

      transport.acceptPendingCandidateHelloForTesting('rift-peer');
      final message = await candidateMessage;
      await transport.sendMessage('rift-peer', Uint8List.fromList([123, 125]));

      expect(message.pendingCandidate, isTrue);
      expect(tls.closedConnectionIds, isEmpty);
      expect(tls.writtenConnectionIds, [42]);
      expect(disconnects, isEmpty);

      await transport.rejectPendingCandidate(message);
      expect(tls.closedConnectionIds, [43]);
      await disconnectSub.cancel();
      await transport.stopServer();
    });

    test(
        'validated candidate with the same role preserves the authenticated session',
        () async {
      final tls = _RecordingNativeTlsApi();
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      final disconnects = <String>[];
      final disconnectSub =
          transport.onPeerDisconnected.listen(disconnects.add);
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
        authenticated: true,
      );
      transport.injectPendingCandidateForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 43,
      );
      final candidateMessage = transport.onMessageReceived.first;

      transport.acceptPendingCandidateHelloForTesting('rift-peer');
      final message = await candidateMessage;
      final promoted = await transport.promotePendingCandidate(message);
      await transport.sendMessage('rift-peer', Uint8List.fromList([123, 125]));

      expect(promoted, isFalse);
      expect(tls.closedConnectionIds, [43]);
      expect(tls.writtenConnectionIds, [42]);
      expect(disconnects, isEmpty);
      await disconnectSub.cancel();
      await transport.stopServer();
    });

    test('connection-scoped teardown preserves a replacement', () async {
      final tls = _RecordingNativeTlsApi();
      final transport = AndroidNativePeerTransport(
        _FakeIdentityManager(),
        port: 0,
        tlsApi: tls,
      );
      final disconnects = <String>[];
      final disconnectSub =
          transport.onPeerDisconnected.listen(disconnects.add);
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 42,
      );
      final oldConnection = transport.currentConnectionToken('rift-peer');
      transport.injectConnectionForTesting(
        peerDeviceId: 'rift-peer',
        connectionId: 43,
      );

      transport.disconnectConnection('rift-peer', oldConnection);
      await Future<void>.delayed(Duration.zero);
      await transport.sendMessage('rift-peer', Uint8List.fromList([123, 125]));

      expect(tls.closedConnectionIds, [42]);
      expect(tls.writtenConnectionIds, [43]);
      expect(disconnects, isEmpty);
      await disconnectSub.cancel();
      await transport.stopServer();
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
