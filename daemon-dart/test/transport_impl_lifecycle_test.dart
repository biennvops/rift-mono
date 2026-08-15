import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';
import 'package:daemon_dart/src/network/transport_impl.dart';
import 'package:test/test.dart';

void main() {
  group('TransportImpl connection ownership', () {
    const peerDeviceId = 'rift-peer';
    late Directory firstDirectory;
    late Directory secondDirectory;
    late IdentityManagerImpl firstIdentity;
    late IdentityManagerImpl secondIdentity;
    late TransportImpl transport;
    late List<_SocketPair> socketPairs;
    late Completer<void> writeStarted;
    late Completer<void> releaseWrite;
    var blockNextWrite = false;
    var failNextWrite = false;

    setUp(() async {
      firstDirectory = await Directory.systemTemp.createTemp(
        'rift_transport_lifecycle_first_',
      );
      secondDirectory = await Directory.systemTemp.createTemp(
        'rift_transport_lifecycle_second_',
      );
      firstIdentity = IdentityManagerImpl(firstDirectory.path);
      secondIdentity = IdentityManagerImpl(secondDirectory.path);
      await Future.wait([
        firstIdentity.initialize(),
        secondIdentity.initialize(),
      ]);

      socketPairs = [];
      writeStarted = Completer<void>();
      releaseWrite = Completer<void>();
      transport = TransportImpl(
        firstIdentity,
        port: 0,
        frameWriter: (socket, frame) async {
          if (blockNextWrite) {
            blockNextWrite = false;
            writeStarted.complete();
            await releaseWrite.future;
          }
          if (failNextWrite) {
            failNextWrite = false;
            throw const SocketException('Injected write failure');
          }
          socket.add(frame);
          await socket.flush();
        },
      );
    });

    tearDown(() async {
      if (!releaseWrite.isCompleted) {
        releaseWrite.complete();
      }
      await transport.stopServer();
      for (final pair in socketPairs) {
        await pair.close();
      }
      await firstIdentity.dispose();
      await secondIdentity.dispose();
      await firstDirectory.delete(recursive: true);
      await secondDirectory.delete(recursive: true);
    });

    Future<_SocketPair> newSocketPair() async {
      final pair = await _openSocketPair(firstIdentity, secondIdentity);
      socketPairs.add(pair);
      return pair;
    }

    test('stale send failure cannot disconnect a replacement socket', () async {
      final firstPair = await newSocketPair();
      final secondPair = await newSocketPair();
      transport.injectConnectionForTesting(peerDeviceId, firstPair.local);
      final oldConnection = transport.currentConnectionToken(peerDeviceId);
      expect(oldConnection, same(firstPair.local));

      final disconnects = <String>[];
      final disconnectSubscription = transport.onPeerDisconnected.listen(
        disconnects.add,
      );
      blockNextWrite = true;
      failNextWrite = true;
      final staleSend = transport.sendMessage(
        peerDeviceId,
        _messageBytes('stale'),
      );
      await writeStarted.future;

      transport.injectConnectionForTesting(peerDeviceId, secondPair.local);
      final replacementConnection = transport.currentConnectionToken(
        peerDeviceId,
      );
      expect(replacementConnection, same(secondPair.local));

      releaseWrite.complete();
      await expectLater(staleSend, throwsA(isA<SocketException>()));

      expect(
        transport.currentConnectionToken(peerDeviceId),
        same(replacementConnection),
      );
      expect(disconnects, isEmpty);
      await transport.sendMessage(peerDeviceId, _messageBytes('current'));

      await disconnectSubscription.cancel();
    });

    test('current socket write failure disconnects that socket', () async {
      final pair = await newSocketPair();
      transport.injectConnectionForTesting(peerDeviceId, pair.local);
      final connection = transport.currentConnectionToken(peerDeviceId);
      expect(connection, same(pair.local));
      final disconnected = transport.onPeerDisconnected.first;

      failNextWrite = true;
      await expectLater(
        transport.sendMessage(peerDeviceId, _messageBytes('failure')),
        throwsA(isA<SocketException>()),
      );

      expect(await disconnected, peerDeviceId);
      expect(transport.currentConnectionToken(peerDeviceId), isNull);
      expect(transport.isCurrentConnection(peerDeviceId, connection), isFalse);
    });

    test('force fresh session replaces the existing socket', () async {
      final serverContext = SecurityContext()
        ..useCertificateChainBytes(
          utf8.encode(secondIdentity.tlsCertificatePem),
        )
        ..usePrivateKeyBytes(utf8.encode(secondIdentity.tlsPrivateKeyPem));
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
        requestClientCertificate: false,
        requireClientCertificate: false,
      );
      final acceptedSockets = <SecureSocket>[];
      final acceptedSubscriptions = <StreamSubscription<Uint8List>>[];
      final serverSubscription = server.listen((socket) {
        acceptedSockets.add(socket);
        acceptedSubscriptions.add(socket.listen((_) {}, onError: (_) {}));
      });
      addTearDown(() async {
        await serverSubscription.cancel();
        await server.close();
        for (final socket in acceptedSockets) {
          socket.destroy();
        }
        for (final subscription in acceptedSubscriptions) {
          await subscription.cancel();
        }
      });

      final connectedPeer = await transport.connectTo(
        InternetAddress.loopbackIPv4.address,
        server.port,
        expectedDeviceId: secondIdentity.deviceId,
      );
      final firstConnection = transport.currentConnectionToken(connectedPeer);
      expect(firstConnection, isNotNull);

      await transport.connectTo(
        InternetAddress.loopbackIPv4.address,
        server.port,
        expectedDeviceId: secondIdentity.deviceId,
        forceFreshSession: true,
      );
      final replacementConnection = transport.currentConnectionToken(
        connectedPeer,
      );
      await Future<void>.delayed(Duration.zero);

      expect(replacementConnection, isNotNull);
      expect(replacementConnection, isNot(same(firstConnection)));
      expect(
        transport.currentConnectionToken(connectedPeer),
        same(replacementConnection),
      );
    });
  });
}

Future<_SocketPair> _openSocketPair(
  IdentityManagerImpl serverIdentity,
  IdentityManagerImpl clientIdentity,
) async {
  final serverContext = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(serverIdentity.tlsCertificatePem))
    ..usePrivateKeyBytes(utf8.encode(serverIdentity.tlsPrivateKeyPem));
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    serverContext,
    requestClientCertificate: false,
    requireClientCertificate: false,
  );
  final accepted = Completer<SecureSocket>();
  final serverSubscription = server.listen(accepted.complete);

  final clientContext = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(clientIdentity.tlsCertificatePem))
    ..usePrivateKeyBytes(utf8.encode(clientIdentity.tlsPrivateKeyPem));
  final remote = await SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
    context: clientContext,
    onBadCertificate: (_) => true,
  );
  final local = await accepted.future;
  await serverSubscription.cancel();
  await server.close();
  final remoteSubscription = remote.listen((_) {}, onError: (_) {});
  return _SocketPair(local, remote, remoteSubscription);
}

class _SocketPair {
  final SecureSocket local;
  final SecureSocket remote;
  final StreamSubscription<Uint8List> remoteSubscription;

  _SocketPair(this.local, this.remote, this.remoteSubscription);

  Future<void> close() async {
    local.destroy();
    remote.destroy();
    await remoteSubscription.cancel();
  }
}

Uint8List _messageBytes(String value) => Uint8List.fromList(
  utf8.encode(json.encode({'type': 'test', 'value': value})),
);
