import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/file_transfer/file_transfer_service.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/operation/operation_manager.dart';
import 'package:test/test.dart';

class FakeTransport implements Transport {
  final _onMessage = StreamController<TransportMessage>.broadcast();
  final _onDisconnect = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sentMessages = [];

  @override
  Stream<TransportMessage> get onMessageReceived => _onMessage.stream;

  @override
  Stream<String> get onPeerDisconnected => _onDisconnect.stream;

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async {
    return expectedDeviceId ?? 'rift-peer';
  }

  @override
  void disconnect(String peerDeviceId) {
    _onDisconnect.add(peerDeviceId);
  }

  @override
  Uint8List? getPeerCert(String peerDeviceId) => Uint8List(32);

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) => null;

  @override
  Future<void> sendMessage(String deviceId, Uint8List payload) async {
    sentMessages.add(json.decode(utf8.decode(payload)) as Map<String, dynamic>);
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {}

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {}

  void simulateIncomingMessage(String deviceId, Map<String, dynamic> payload) {
    _onMessage.add(
      TransportMessage(
        peerDeviceId: deviceId,
        payload: Uint8List.fromList(utf8.encode(json.encode(payload))),
        peerEd25519Key: Uint8List(32),
        peerCertDer: Uint8List(32),
      ),
    );
  }
}

class FakeIdentityManager implements IdentityManager {
  @override
  String get deviceId => 'rift-local';
  @override
  String get displayName => 'Android Phone 01';

  @override
  Future<String> generateIdentityProof(
    Uint8List channelBinding,
    Uint8List peerCertDer,
  ) async {
    return 'proof';
  }

  @override
  Uint8List getDeviceFingerprint() => Uint8List(32);

  @override
  Uint8List get tlsCertificateDer => Uint8List(32);

  @override
  String get tlsCertificatePem => 'cert';

  @override
  String get tlsPrivateKeyPem => 'key';

  @override
  Uint8List getEd25519PublicKey() => Uint8List(32);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}
}

class FakeTrustStore implements TrustStore {
  @override
  Future<void> initialize() async {}

  @override
  Future<List<PeerRecord>> getAllPeers() async => [];

  @override
  Future<void> upsertPeer(PeerRecord record) async {}

  @override
  Future<PeerRecord?> getPeer(String deviceId) async => PeerRecord(
        deviceId: deviceId,
        certDer: Uint8List(32),
        state: TrustState.trusted,
        updatedAt: DateTime.now().toUtc(),
      );

  @override
  Future<List<PeerRecord>> getPeersByState(TrustState state) async => [];

  @override
  Future<bool> transitionState(
    String deviceId,
    TrustState from,
    TrustState to, {
    DateTime? pairedAt,
  }) async {
    return true;
  }

  @override
  Future<void> deletePeer(String deviceId) async {}

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}

  @override
  Future<void> appendSecurityEvent(SecurityEventRecord record) async {}

  @override
  Future<List<SecurityEventRecord>> querySecurityEvents(
    SecurityEventQuery query,
  ) async {
    return [];
  }

  @override
  Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;
}

void main() {
  group('FileTransferService', () {
    late FakeTransport transport;
    late SessionManager sessionManager;
    late OperationManager operationManager;
    late FileTransferService service;
    late Directory tempDir;

    setUp(() async {
      transport = FakeTransport();
      sessionManager = SessionManager(
        transport,
        FakeIdentityManager(),
        FakeTrustStore(),
      );
      operationManager = OperationManager();
      tempDir = await Directory.systemTemp.createTemp('rift-file-transfer-test');
      service = FileTransferService(
        sessionManager: sessionManager,
        trustStore: FakeTrustStore(),
        operationManager: operationManager,
        localDeviceId: 'rift-local',
        storagePath: tempDir.path,
      );

      final ctx = SessionContext(peerDeviceId: 'rift-peer', isInitiator: true)
        ..handshakeState = HandshakeState.established
        ..trustState = TrustState.trusted
        ..capabilityNegotiated = true
        ..negotiatedCapabilities = [
          Capability(name: 'file.transfer', version: 1),
        ];
      sessionManager.injectContextForTesting(ctx);
    });

    tearDown(() async {
      await service.dispose();
      operationManager.dispose();
      sessionManager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('stores incoming file offers and emits notification payload', () async {
      final offerFuture = service.onFileOffer.first;

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '11111111-1111-4111-8111-111111111111',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': '22222222-2222-4222-8222-222222222222',
          'fileName': 'hello.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
          'sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'chunkSize': 262144,
          'chunkCount': 1,
          'expiresInMs': 300000,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });

      final notification = await offerFuture;
      final offers = service.listIncomingFileOffers();

      expect(notification['transferId'], '22222222-2222-4222-8222-222222222222');
      expect(notification['sourceDeviceId'], 'rift-peer');
      expect(offers, hasLength(1));
      expect(offers.single['fileName'], 'hello.txt');
    });

    test('rejects oversized incoming file offers', () async {
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '99999999-9999-4999-8999-999999999999',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'fileName': 'huge.bin',
          'mediaType': 'application/octet-stream',
          'byteSize': 33554433,
          'sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'chunkSize': 262144,
          'chunkCount': 1,
          'expiresInMs': 300000,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(service.listIncomingFileOffers(), isEmpty);
    });

    test('rejects negative byteSize in incoming file offers', () async {
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '10101010-1010-4010-8010-101010101010',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          'fileName': 'bad.bin',
          'mediaType': 'application/octet-stream',
          'byteSize': -1,
          'sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'chunkSize': 262144,
          'chunkCount': 1,
          'expiresInMs': 300000,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(service.listIncomingFileOffers(), isEmpty);
    });

    test('rejects nonpositive expiresInMs in incoming file offers', () async {
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '20202020-2020-4020-8020-202020202020',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'fileName': 'bad.bin',
          'mediaType': 'application/octet-stream',
          'byteSize': 5,
          'sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'chunkSize': 262144,
          'chunkCount': 1,
          'expiresInMs': 0,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(service.listIncomingFileOffers(), isEmpty);
    });

    test('sends file chunks and completion after peer accepts an outgoing offer', () async {
      final localFile = File('${tempDir.path}${Platform.pathSeparator}sample.txt');
      await localFile.writeAsString('hello world');

      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
      );

      expect(transport.sentMessages.first['type'], 'file.offer');

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '33333333-3333-4333-8333-333333333333',
        'type': 'file.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'chunkSize': 262144,
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        transport.sentMessages.any((message) => message['type'] == 'file.chunk'),
        isTrue,
      );
      expect(
        transport.sentMessages.any((message) => message['type'] == 'file.complete'),
        isTrue,
      );
    });

    test('rejects dot-only incoming file names before staging', () async {
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '44444444-4444-4444-8444-444444444444',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': '55555555-5555-4555-8555-555555555555',
          'fileName': '.',
          'mediaType': 'text/plain',
          'byteSize': 5,
          'sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'chunkSize': 262144,
          'chunkCount': 1,
          'expiresInMs': 300000,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        service.acceptFileOffer(
          transferId: '55555555-5555-4555-8555-555555555555',
          destinationPath:
              '${tempDir.path}${Platform.pathSeparator}received.txt',
        ),
        throwsA(
          isA<RiftException>().having(
            (error) => error.message,
            'message',
            contains('invalid file name'),
          ),
        ),
      );
    });

    test('uses basename for incoming staging path', () async {
      const transferId = '66666666-6666-4666-8666-666666666666';
      const sha256Hex =
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '77777777-7777-4777-8777-777777777777',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': transferId,
          'fileName': '../../escaped',
          'mediaType': 'text/plain',
          'byteSize': 5,
          'sha256': sha256Hex,
          'chunkSize': 262144,
          'chunkCount': 1,
          'expiresInMs': 300000,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });
      await Future<void>.delayed(Duration.zero);

      final outsideFile = File(
        '${tempDir.path}${Platform.pathSeparator}escaped.part',
      );
      if (await outsideFile.exists()) {
        await outsideFile.delete();
      }

      await service.acceptFileOffer(
        transferId: transferId,
        destinationPath: '${tempDir.path}${Platform.pathSeparator}received.txt',
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '88888888-8888-4888-8888-888888888888',
        'type': 'file.chunk',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': transferId,
          'chunkIndex': 0,
          'offset': 0,
          'byteSize': 5,
          'chunkSha256': sha256Hex,
          'contentBase64': base64.encode(utf8.encode('hello')),
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await outsideFile.exists(), isFalse);
    });
  });
}
