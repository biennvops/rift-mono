import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  });
}
