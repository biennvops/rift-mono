import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

class CancelOnFirstChunkTransport extends FakeTransport {
  CancelOnFirstChunkTransport(this.peerDeviceId);

  final String peerDeviceId;
  String? transferId;
  bool _cancelSent = false;

  @override
  Future<void> sendMessage(String deviceId, Uint8List payload) async {
    await super.sendMessage(deviceId, payload);
    final message = sentMessages.last;
    if (_cancelSent ||
        deviceId != peerDeviceId ||
        message['type']?.toString() != 'file.chunk') {
      return;
    }

    final currentTransferId = transferId;
    if (currentTransferId == null || currentTransferId.isEmpty) {
      return;
    }

    _cancelSent = true;
    simulateIncomingMessage(peerDeviceId, {
      'rift': '0.1-draft',
      'messageId': 'abababab-abab-4bab-8bab-abababababab',
      'type': 'file.cancel',
      'sourceDeviceId': peerDeviceId,
      'destinationDeviceId': 'rift-local',
      'payload': {
        'transferId': currentTransferId,
        'failureReason': 'PolicyDenied',
        'message': 'peer cancelled',
      },
    });
    await Future<void>.delayed(Duration.zero);
  }
}

class FailFirstChunkTransport extends FakeTransport {
  bool _failed = false;

  @override
  Future<void> sendMessage(String deviceId, Uint8List payload) async {
    final decoded = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    sentMessages.add(decoded);
    if (!_failed && decoded['type']?.toString() == 'file.chunk') {
      _failed = true;
      throw const SocketException('simulated connection reset');
    }
  }
}

class FailSecondChunkTransport extends FakeTransport {
  var _chunkCount = 0;

  @override
  Future<void> sendMessage(String deviceId, Uint8List payload) async {
    final decoded = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    sentMessages.add(decoded);
    if (decoded['type']?.toString() == 'file.chunk' && ++_chunkCount == 2) {
      throw const SocketException('simulated connection reset');
    }
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
      tempDir = await Directory.systemTemp.createTemp(
        'rift-file-transfer-test',
      );
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

      expect(
        notification['transferId'],
        '22222222-2222-4222-8222-222222222222',
      );
      expect(notification['sourceDeviceId'], 'rift-peer');
      expect(offers, hasLength(1));
      expect(offers.single['fileName'], 'hello.txt');
    });

    test('accepts incoming file offers larger than 32 MiB', () async {
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
          'chunkCount': 129,
          'expiresInMs': 300000,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });
      await Future<void>.delayed(Duration.zero);

      final offers = service.listIncomingFileOffers();
      expect(offers, hasLength(1));
      expect(offers.single['transferId'], 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(offers.single['byteSize'], 33554433);
      expect(offers.single['chunkCount'], 129);
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

    test(
      'sends file chunks and completion after peer accepts an outgoing offer',
      () async {
        final localFile = File(
          '${tempDir.path}${Platform.pathSeparator}sample.txt',
        );
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
          transport.sentMessages.any(
            (message) => message['type'] == 'file.chunk',
          ),
          isTrue,
        );
        expect(
          transport.sentMessages.any(
            (message) => message['type'] == 'file.complete',
          ),
          isTrue,
        );
      },
    );

    test('stops outgoing send after remote cancel', () async {
      await service.dispose();
      await sessionManager.dispose();

      transport = CancelOnFirstChunkTransport('rift-peer');
      sessionManager = SessionManager(
        transport,
        FakeIdentityManager(),
        FakeTrustStore(),
      );
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

      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}large-sample.txt',
      );
      await localFile.writeAsString('a' * 600000);

      final failedFuture = service.onTransferFailed.firstWhere(
        (event) => event['failureReason'] == 'PolicyDenied',
      );

      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
        fileName: 'large-sample.txt',
      );

      (transport as CancelOnFirstChunkTransport).transferId = result.transferId;
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '67676767-6767-4767-8767-676767676767',
        'type': 'file.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'chunkSize': 262144,
        },
      });

      await failedFuture.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        transport.sentMessages.where((message) => message['type'] == 'file.chunk'),
        hasLength(1),
      );
      expect(
        transport.sentMessages.any((message) => message['type'] == 'file.complete'),
        isFalse,
      );
    });

    test('preserves outgoing transfer state after recoverable disconnect', () async {
      await service.dispose();
      await sessionManager.dispose();

      transport = FailFirstChunkTransport();
      sessionManager = SessionManager(
        transport,
        FakeIdentityManager(),
        FakeTrustStore(),
      );
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

      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}resume-sample.txt',
      );
      await localFile.writeAsString('a' * 600000);

      final failedFuture = service.onTransferFailed.firstWhere(
        (event) => event['failureReason'] == 'ConnectionLost',
      );

      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
        fileName: 'resume-sample.txt',
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '78787878-7878-4787-8787-787878787878',
        'type': 'file.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'chunkSize': 262144,
        },
      });

      await failedFuture.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final transfers = service.listFileTransfers();
      expect(
        transfers.any(
          (transfer) =>
              transfer['transferId'] == result.transferId &&
              transfer['direction'] == 'outgoing' &&
              transfer['failureReason'] == 'ConnectionLost',
        ),
        isTrue,
      );
    });

    test('resumes outgoing transfer from requested offset', () async {
      await service.dispose();
      await sessionManager.dispose();

      transport = FailSecondChunkTransport();
      sessionManager = SessionManager(
        transport,
        FakeIdentityManager(),
        FakeTrustStore(),
      );
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

      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}resume-offset.txt',
      );
      await localFile.writeAsString('a' * 600000);

      final failedFuture = service.onTransferFailed.firstWhere(
        (event) => event['failureReason'] == 'ConnectionLost',
      );
      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
        fileName: 'resume-offset.txt',
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '81818181-8181-4818-8818-818181818181',
        'type': 'file.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'chunkSize': 262144,
        },
      });
      await failedFuture.timeout(const Duration(seconds: 2));

      transport.sentMessages.removeWhere((message) => message['type'] == 'file.chunk');
      transport.sentMessages.removeWhere((message) => message['type'] == 'file.complete');

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '82828282-8282-4828-8828-828282828282',
        'type': 'file.resume',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'nextChunkIndex': 1,
          'offset': 262144,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final resumedChunks = transport.sentMessages
          .where((message) => message['type'] == 'file.chunk')
          .toList(growable: false);
      expect(resumedChunks, isNotEmpty);
      expect(resumedChunks.first['payload']['chunkIndex'], 1);
      expect(resumedChunks.first['payload']['offset'], 262144);
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

    test(
      'completed incoming transfer notification carries destinationPath',
      () async {
        const transferId = '99999999-9999-4999-8999-999999999999';
        const sha256Hex =
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
        final destinationPath =
            '${tempDir.path}${Platform.pathSeparator}received-final.txt';
        final completedFuture = service.onTransferCompleted.first;

        transport.simulateIncomingMessage('rift-peer', {
          'rift': '0.1-draft',
          'messageId': '12121212-1212-4212-8212-121212121212',
          'type': 'file.offer',
          'sourceDeviceId': 'rift-peer',
          'destinationDeviceId': 'rift-local',
          'payload': {
            'transferId': transferId,
            'fileName': 'hello.txt',
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

        await service.acceptFileOffer(
          transferId: transferId,
          destinationPath: destinationPath,
        );

        transport.simulateIncomingMessage('rift-peer', {
          'rift': '0.1-draft',
          'messageId': '13131313-1313-4313-8313-131313131313',
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
            'isLastChunk': true,
          },
        });

        transport.simulateIncomingMessage('rift-peer', {
          'rift': '0.1-draft',
          'messageId': '14141414-1414-4414-8414-141414141414',
          'type': 'file.complete',
          'sourceDeviceId': 'rift-peer',
          'destinationDeviceId': 'rift-local',
          'payload': {
            'transferId': transferId,
            'byteSize': 5,
            'sha256': sha256Hex,
            'chunkCount': 1,
          },
        });

        final completed = await completedFuture;
        expect(completed['destinationPath'], destinationPath);
      },
    );

    test('processes large final chunk before completion from same peer', () async {
      const transferId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
      final content = 'a' * 600000;
      final bytes = utf8.encode(content);
      final sha256Hex = sha256.convert(bytes).toString();
      final destinationPath =
          '${tempDir.path}${Platform.pathSeparator}received-large.txt';
      final completedFuture = service.onTransferCompleted.firstWhere(
        (event) => event['transferId'] == transferId,
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '15151515-1515-4515-8515-151515151515',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': transferId,
          'fileName': 'large.txt',
          'mediaType': 'text/plain',
          'byteSize': bytes.length,
          'sha256': sha256Hex,
          'chunkSize': 262144,
          'chunkCount': 3,
          'expiresInMs': 300000,
          'sourceDeviceId': 'rift-peer',
          'requiredCapability': 'file.transfer',
        },
      });
      await Future<void>.delayed(Duration.zero);

      await service.acceptFileOffer(
        transferId: transferId,
        destinationPath: destinationPath,
      );

      var offset = 0;
      for (var chunkIndex = 0; chunkIndex < 3; chunkIndex += 1) {
        final end = (offset + 262144 < bytes.length)
            ? offset + 262144
            : bytes.length;
        final chunkBytes = bytes.sublist(offset, end);
        final chunkSha256 = sha256.convert(chunkBytes).toString();
        transport.simulateIncomingMessage('rift-peer', {
          'rift': '0.1-draft',
          'messageId':
              '16161616-1616-4616-8616-${chunkIndex.toString().padLeft(12, '0')}',
          'type': 'file.chunk',
          'sourceDeviceId': 'rift-peer',
          'destinationDeviceId': 'rift-local',
          'payload': {
            'transferId': transferId,
            'chunkIndex': chunkIndex,
            'offset': offset,
            'byteSize': chunkBytes.length,
            'chunkSha256': chunkSha256,
            'contentBase64': base64.encode(chunkBytes),
            'isLastChunk': chunkIndex == 2,
          },
        });
        offset = end;
      }

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '17171717-1717-4717-8717-171717171717',
        'type': 'file.complete',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': transferId,
          'byteSize': bytes.length,
          'sha256': sha256Hex,
          'chunkCount': 3,
        },
      });

      final completed = await completedFuture.timeout(const Duration(seconds: 2));
      expect(completed['destinationPath'], destinationPath);
      expect(await File(destinationPath).readAsString(), content);
    });
  });
}
