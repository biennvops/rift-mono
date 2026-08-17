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
import 'package:daemon_dart/src/operation/operation_models.dart';
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

class ControlledResumeTransport extends FakeTransport {
  final Map<String, int> resumeCallsByPeer = {};
  final Map<String, int> activeResumeCallsByPeer = {};
  final Map<String, int> maxActiveResumeCallsByPeer = {};
  final Map<String, Completer<void>> _resumeBlockers = {};
  final Map<String, int> _resumeFailuresRemaining = {};
  final List<({String peerDeviceId, int count, Completer<void> completer})>
  _resumeWaiters = [];

  int activeResumeCalls = 0;
  int maxActiveResumeCalls = 0;

  void blockResume(String peerDeviceId) {
    _resumeBlockers[peerDeviceId] = Completer<void>();
  }

  void releaseResume(String peerDeviceId) {
    final blocker = _resumeBlockers.remove(peerDeviceId);
    if (blocker != null && !blocker.isCompleted) {
      blocker.complete();
    }
  }

  void failNextResume(String peerDeviceId) {
    _resumeFailuresRemaining[peerDeviceId] =
        (_resumeFailuresRemaining[peerDeviceId] ?? 0) + 1;
  }

  Future<void> waitForResumeCount(String peerDeviceId, int count) {
    if ((resumeCallsByPeer[peerDeviceId] ?? 0) >= count) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _resumeWaiters.add((
      peerDeviceId: peerDeviceId,
      count: count,
      completer: completer,
    ));
    return completer.future;
  }

  @override
  Future<void> sendMessage(String deviceId, Uint8List payload) async {
    final decoded = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    if (decoded['type'] != 'file.resume') {
      await super.sendMessage(deviceId, payload);
      return;
    }

    sentMessages.add(decoded);
    final peerCalls = (resumeCallsByPeer[deviceId] ?? 0) + 1;
    resumeCallsByPeer[deviceId] = peerCalls;
    activeResumeCalls++;
    activeResumeCallsByPeer[deviceId] =
        (activeResumeCallsByPeer[deviceId] ?? 0) + 1;
    if (activeResumeCalls > maxActiveResumeCalls) {
      maxActiveResumeCalls = activeResumeCalls;
    }
    final peerActive = activeResumeCallsByPeer[deviceId]!;
    if (peerActive > (maxActiveResumeCallsByPeer[deviceId] ?? 0)) {
      maxActiveResumeCallsByPeer[deviceId] = peerActive;
    }
    _completeResumeWaiters(deviceId, peerCalls);

    try {
      final blocker = _resumeBlockers[deviceId];
      if (blocker != null) {
        await blocker.future;
      }
      final failuresRemaining = _resumeFailuresRemaining[deviceId] ?? 0;
      if (failuresRemaining > 0) {
        _resumeFailuresRemaining[deviceId] = failuresRemaining - 1;
        throw const SocketException('simulated resume failure');
      }
    } finally {
      activeResumeCalls--;
      activeResumeCallsByPeer[deviceId] =
          activeResumeCallsByPeer[deviceId]! - 1;
    }
  }

  void _completeResumeWaiters(String peerDeviceId, int count) {
    for (final waiter in List.of(_resumeWaiters)) {
      if (waiter.peerDeviceId == peerDeviceId && waiter.count <= count) {
        _resumeWaiters.remove(waiter);
        waiter.completer.complete();
      }
    }
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

class FailCompleteTransport extends FakeTransport {
  bool _failed = false;

  @override
  Future<void> sendMessage(String deviceId, Uint8List payload) async {
    final decoded = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    sentMessages.add(decoded);
    if (!_failed && decoded['type']?.toString() == 'file.complete') {
      _failed = true;
      throw const SocketException('simulated completion send failure');
    }
  }
}

class BlockChunkTransport extends FakeTransport {
  final chunkBlocked = Completer<void>();
  final _releaseChunk = Completer<void>();

  @override
  Future<void> sendMessage(String deviceId, Uint8List payload) async {
    await super.sendMessage(deviceId, payload);
    if (sentMessages.last['type'] == 'file.chunk') {
      if (!chunkBlocked.isCompleted) {
        chunkBlocked.complete();
      }
      await _releaseChunk.future;
    }
  }

  void releaseChunk() {
    if (!_releaseChunk.isCompleted) {
      _releaseChunk.complete();
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

SessionContext _ensureFileTransferContext(
  SessionManager sessionManager,
  String peerDeviceId,
) {
  final existing = sessionManager.getContext(peerDeviceId);
  if (existing != null) return existing;

  final context = SessionContext(peerDeviceId: peerDeviceId, isInitiator: true)
    ..handshakeState = HandshakeState.established
    ..trustState = TrustState.trusted
    ..capabilityNegotiated = true
    ..negotiatedCapabilities = [Capability(name: 'file.transfer', version: 1)];
  sessionManager.injectContextForTesting(context);
  return context;
}

Future<SessionContext> _addResumableIncomingTransfer({
  required FileTransferService service,
  required FakeTransport transport,
  required SessionManager sessionManager,
  required Directory tempDir,
  required String peerDeviceId,
  required String transferId,
  required String messageId,
}) async {
  final context = _ensureFileTransferContext(sessionManager, peerDeviceId);
  final offerReceived = service.onFileOffer.firstWhere(
    (offer) => offer['transferId'] == transferId,
  );
  transport.simulateIncomingMessage(peerDeviceId, {
    'rift': '0.1-draft',
    'messageId': messageId,
    'type': 'file.offer',
    'sourceDeviceId': peerDeviceId,
    'destinationDeviceId': 'rift-local',
    'payload': {
      'transferId': transferId,
      'fileName': '$transferId.txt',
      'mediaType': 'text/plain',
      'byteSize': 5,
      'sha256':
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      'chunkSize': 262144,
      'chunkCount': 1,
      'expiresInMs': 300000,
      'sourceDeviceId': peerDeviceId,
      'requiredCapability': 'file.transfer',
    },
  });
  await offerReceived;
  await service.acceptFileOffer(
    transferId: transferId,
    destinationPath:
        '${tempDir.path}${Platform.pathSeparator}$peerDeviceId-$transferId.txt',
  );
  return context;
}

void main() {
  group('FileTransferService', () {
    late FakeTransport transport;
    late SessionManager sessionManager;
    late OperationManager operationManager;
    late FileTransferService service;
    late Directory tempDir;
    StreamController<SessionContext>? trustedReadyController;

    setUp(() async {
      trustedReadyController = null;
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
      await trustedReadyController?.close();
      operationManager.dispose();
      await sessionManager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<ControlledResumeTransport> useControlledResumeTransport() async {
      await service.dispose();
      await sessionManager.dispose();

      final controlledTransport = ControlledResumeTransport();
      final readyController = StreamController<SessionContext>.broadcast(
        sync: true,
      );
      trustedReadyController = readyController;
      transport = controlledTransport;
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
        trustedSessionReady: readyController.stream,
      );
      return controlledTransport;
    }

    void emitTrustedSessionReady(SessionContext context) {
      trustedReadyController!.add(context);
    }

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
      expect(
        offers.single['transferId'],
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
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

    test('uses a positive chunk count when offering an empty file', () async {
      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}empty.txt',
      );
      await localFile.writeAsBytes([]);

      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
      );
      final offer = transport.sentMessages.singleWhere(
        (message) => message['type'] == 'file.offer',
      );

      expect(result.chunkCount, 1);
      expect(offer['payload']['chunkCount'], 1);

      final completedFuture = service.onTransferCompleted.firstWhere(
        (event) => event['transferId'] == result.transferId,
      );
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '22222222-2222-4222-8222-222222222222',
        'type': 'file.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'chunkSize': 262144,
        },
      });
      await completedFuture.timeout(const Duration(seconds: 2));

      final chunk = transport.sentMessages.singleWhere(
        (message) => message['type'] == 'file.chunk',
      );
      expect(chunk['payload']['chunkIndex'], 0);
      expect(chunk['payload']['byteSize'], 0);
      expect(chunk['payload']['contentBase64'], '');
      expect(chunk['payload']['isLastChunk'], isTrue);
      expect(
        operationManager.getOperation(result.operationId).state,
        OperationState.done,
      );
    });

    test('rejects zero chunkCount in incoming file offers', () async {
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '21212121-2121-4121-8121-212121212121',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          'fileName': 'empty.bin',
          'mediaType': 'application/octet-stream',
          'byteSize': 0,
          'sha256':
              'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          'chunkSize': 262144,
          'chunkCount': 0,
          'expiresInMs': 300000,
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

    test(
      'preserves chunk counts and hashes across boundaries and negotiated sizes',
      () async {
        var messageSequence = 0;

        Future<void> verifyTransfer(int byteSize, int chunkSize) async {
          transport.sentMessages.clear();
          final original = Uint8List.fromList(
            List<int>.generate(byteSize, (index) => (index * 31 + 7) & 0xff),
          );
          final localFile = File(
            '${tempDir.path}${Platform.pathSeparator}'
            'integrity-$chunkSize-$byteSize.bin',
          );
          await localFile.writeAsBytes(original);
          final result = await service.offerFile(
            targetDeviceId: 'rift-peer',
            localPath: localFile.path,
          );
          final completed = service.onTransferCompleted.firstWhere(
            (event) => event['transferId'] == result.transferId,
          );
          messageSequence++;
          transport.simulateIncomingMessage('rift-peer', {
            'rift': '0.1-draft',
            'messageId':
                '44444444-4444-4444-8444-${messageSequence.toString().padLeft(12, '0')}',
            'type': 'file.accept',
            'sourceDeviceId': 'rift-peer',
            'destinationDeviceId': 'rift-local',
            'payload': {
              'transferId': result.transferId,
              'receivingDeviceId': 'rift-peer',
              'chunkSize': chunkSize,
            },
          });
          await completed.timeout(const Duration(seconds: 5));

          final chunks = transport.sentMessages
              .where((message) => message['type'] == 'file.chunk')
              .where(
                (message) =>
                    (message['payload']
                        as Map<String, dynamic>)['transferId'] ==
                    result.transferId,
              )
              .map((message) => message['payload'] as Map<String, dynamic>)
              .toList(growable: false);
          final expectedCount = byteSize == 0
              ? 1
              : ((byteSize + chunkSize) - 1) ~/ chunkSize;
          expect(chunks, hasLength(expectedCount));

          final reconstructed = BytesBuilder(copy: false);
          var expectedOffset = 0;
          for (var index = 0; index < chunks.length; index++) {
            final chunk = chunks[index];
            final decoded = base64.decode(chunk['contentBase64'] as String);
            expect(chunk['chunkIndex'], index);
            expect(chunk['offset'], expectedOffset);
            expect(chunk['byteSize'], decoded.length);
            expect(chunk['chunkSha256'], sha256.convert(decoded).toString());
            expect(chunk['isLastChunk'], index == chunks.length - 1);
            reconstructed.add(decoded);
            expectedOffset += decoded.length;
          }
          final reconstructedBytes = reconstructed.takeBytes();
          expect(reconstructedBytes, original);
          expect(
            sha256.convert(reconstructedBytes).toString(),
            sha256.convert(original).toString(),
          );

          final completion = transport.sentMessages.singleWhere(
            (message) =>
                message['type'] == 'file.complete' &&
                (message['payload'] as Map<String, dynamic>)['transferId'] ==
                    result.transferId,
          );
          expect(
            (completion['payload'] as Map<String, dynamic>)['chunkCount'],
            expectedCount,
          );
        }

        const baselineChunkSize = FileTransferService.defaultChunkSize;
        for (final byteSize in [
          0,
          1,
          baselineChunkSize - 1,
          baselineChunkSize,
          baselineChunkSize + 1,
          baselineChunkSize * 2 + 17,
        ]) {
          await verifyTransfer(byteSize, baselineChunkSize);
        }
        for (final chunkSize in [64 * 1024, 512 * 1024, 1024 * 1024]) {
          await verifyTransfer(chunkSize * 2 + 17, chunkSize);
        }
      },
    );

    test('rejects resume before an outgoing transfer is accepted', () async {
      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}not-accepted.txt',
      );
      await localFile.writeAsString('hello');
      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '35353535-3535-4535-8535-353535353535',
        'type': 'file.resume',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'nextChunkIndex': 0,
          'offset': 0,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        transport.sentMessages.any(
          (message) => message['type'] == 'file.chunk',
        ),
        isFalse,
      );
      expect(service.listFileTransfers().single['state'], 'dispatched');
    });

    test('rejects resume while an outgoing transfer is active', () async {
      await service.dispose();
      await sessionManager.dispose();

      final blockingTransport = BlockChunkTransport();
      transport = blockingTransport;
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
        '${tempDir.path}${Platform.pathSeparator}active.txt',
      );
      await localFile.writeAsString('a' * 600000);
      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
      );
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '36363636-3636-4636-8636-363636363636',
        'type': 'file.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'chunkSize': 262144,
        },
      });
      await blockingTransport.chunkBlocked.future.timeout(
        const Duration(seconds: 2),
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '37373737-3737-4737-8737-373737373737',
        'type': 'file.resume',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'nextChunkIndex': 0,
          'offset': 0,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        transport.sentMessages.where(
          (message) => message['type'] == 'file.chunk',
        ),
        hasLength(1),
      );
      blockingTransport.releaseChunk();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('uses negotiated chunk count in completion metadata', () async {
      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}negotiated-chunks.txt',
      );
      await localFile.writeAsString('a' * 600000);

      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
      );
      expect(result.chunkCount, 3);
      final completedFuture = service.onTransferCompleted.firstWhere(
        (event) => event['transferId'] == result.transferId,
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '34343434-3434-4434-8434-343434343434',
        'type': 'file.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'chunkSize': 524288,
        },
      });
      await completedFuture.timeout(const Duration(seconds: 2));

      expect(
        transport.sentMessages.where(
          (message) => message['type'] == 'file.chunk',
        ),
        hasLength(2),
      );
      final complete = transport.sentMessages.singleWhere(
        (message) => message['type'] == 'file.complete',
      );
      expect(complete['payload']['chunkCount'], 2);
    });

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
        transport.sentMessages.where(
          (message) => message['type'] == 'file.chunk',
        ),
        hasLength(1),
      );
      expect(
        transport.sentMessages.any(
          (message) => message['type'] == 'file.complete',
        ),
        isFalse,
      );
    });

    test(
      'preserves outgoing transfer state after recoverable disconnect',
      () async {
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
                transfer['state'] == 'paused' &&
                transfer['failureReason'] == 'ConnectionLost',
          ),
          isTrue,
        );
        expect(
          operationManager.getOperation(result.operationId).state,
          OperationState.active,
        );
      },
    );

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

      transport.sentMessages.removeWhere(
        (message) => message['type'] == 'file.chunk',
      );
      transport.sentMessages.removeWhere(
        (message) => message['type'] == 'file.complete',
      );
      final completedFuture = service.onTransferCompleted.firstWhere(
        (event) => event['transferId'] == result.transferId,
      );

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
      await completedFuture.timeout(const Duration(seconds: 2));
      expect(
        operationManager.getOperation(result.operationId).state,
        OperationState.done,
      );
      expect(
        service.listFileTransfers().any(
          (transfer) => transfer['transferId'] == result.transferId,
        ),
        isFalse,
      );
    });

    test('resends completion when resumed after the final chunk', () async {
      await service.dispose();
      await sessionManager.dispose();

      transport = FailCompleteTransport();
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
        '${tempDir.path}${Platform.pathSeparator}resume-complete.txt',
      );
      await localFile.writeAsString('hello');
      final failedFuture = service.onTransferFailed.firstWhere(
        (event) => event['failureReason'] == 'ConnectionLost',
      );
      final result = await service.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: localFile.path,
        fileName: 'resume-complete.txt',
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '83838383-8383-4383-8383-838383838383',
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
      final completedFuture = service.onTransferCompleted.firstWhere(
        (event) => event['transferId'] == result.transferId,
      );

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '84848484-8484-4484-8484-848484848484',
        'type': 'file.resume',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': result.transferId,
          'receivingDeviceId': 'rift-peer',
          'nextChunkIndex': 1,
          'offset': 5,
        },
      });

      await completedFuture.timeout(const Duration(seconds: 2));
      expect(
        transport.sentMessages.where(
          (message) => message['type'] == 'file.complete',
        ),
        hasLength(2),
      );
      expect(
        operationManager.getOperation(result.operationId).state,
        OperationState.done,
      );
    });

    test('requests resume for a zero-byte transfer', () async {
      const transferId = '86868686-8686-4686-8686-868686868686';
      const sha256Hex =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '84848484-8484-4484-8484-848484848484',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': transferId,
          'fileName': 'resume-zero.txt',
          'mediaType': 'text/plain',
          'byteSize': 0,
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
        destinationPath:
            '${tempDir.path}${Platform.pathSeparator}resume-zero.txt',
      );

      final requiredCapabilities = [
        'clipboard.offer_fetch',
        'file.transfer',
        'presence.basic',
        'operation.lifecycle',
        'security.event_log',
      ];
      final ctx = sessionManager.getContext('rift-peer')!
        ..localAdvertisedCapabilities = requiredCapabilities
            .map((name) => Capability(name: name, version: 1))
            .toList();
      ctx.capabilityNegotiated = false;
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '87878787-8787-4787-8787-878787878787',
        'type': 'capability.advertise',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'capabilities': requiredCapabilities
              .map((name) => {'name': name, 'version': 1})
              .toList(),
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final resume = transport.sentMessages.lastWhere(
        (message) => message['type'] == 'file.resume',
      );
      expect(resume['payload']['transferId'], transferId);
      expect(resume['payload']['nextChunkIndex'], 0);
      expect(resume['payload']['offset'], 0);
    });

    test('requests resume after receiving the final chunk', () async {
      const transferId = '88888888-8888-4888-8888-888888888888';
      const sha256Hex =
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '89898989-8989-4989-8989-898989898989',
        'type': 'file.offer',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'transferId': transferId,
          'fileName': 'resume-final.txt',
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
        destinationPath:
            '${tempDir.path}${Platform.pathSeparator}resume-final.txt',
      );
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '90909090-9090-4090-9090-909090909090',
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
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final requiredCapabilities = [
        'clipboard.offer_fetch',
        'file.transfer',
        'presence.basic',
        'operation.lifecycle',
        'security.event_log',
      ];
      final ctx = sessionManager.getContext('rift-peer')!
        ..localAdvertisedCapabilities = requiredCapabilities
            .map((name) => Capability(name: name, version: 1))
            .toList();
      ctx.capabilityNegotiated = false;
      transport.simulateIncomingMessage('rift-peer', {
        'rift': '0.1-draft',
        'messageId': '91919191-9191-4191-9191-919191919191',
        'type': 'capability.advertise',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'capabilities': requiredCapabilities
              .map((name) => {'name': name, 'version': 1})
              .toList(),
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final resume = transport.sentMessages.lastWhere(
        (message) => message['type'] == 'file.resume',
      );
      expect(resume['payload']['transferId'], transferId);
      expect(resume['payload']['nextChunkIndex'], 1);
      expect(resume['payload']['offset'], 5);
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

    test(
      'processes large final chunk before completion from same peer',
      () async {
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

        final completed = await completedFuture.timeout(
          const Duration(seconds: 2),
        );
        expect(completed['destinationPath'], destinationPath);
        expect(await File(destinationPath).readAsString(), content);
      },
    );

    test('cancels trusted-session readiness on dispose', () async {
      final controlledTransport = await useControlledResumeTransport();
      final context = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer',
        transferId: '18181818-1818-4818-8818-181818181818',
        messageId: '19191919-1919-4919-8919-191919191919',
      );

      await service.dispose();
      emitTrustedSessionReady(context);

      expect(controlledTransport.resumeCallsByPeer['rift-peer'] ?? 0, 0);
      expect(
        controlledTransport.sentMessages.where(
          (message) => message['type'] == 'file.resume',
        ),
        isEmpty,
      );
    });

    test(
      'dispose prevents active resume work from starting more sends',
      () async {
        final controlledTransport = await useControlledResumeTransport();
        final context = await _addResumableIncomingTransfer(
          service: service,
          transport: controlledTransport,
          sessionManager: sessionManager,
          tempDir: tempDir,
          peerDeviceId: 'rift-peer',
          transferId: '20202020-2020-4020-8020-202020202020',
          messageId: '21212121-2121-4121-8121-212121212121',
        );
        await _addResumableIncomingTransfer(
          service: service,
          transport: controlledTransport,
          sessionManager: sessionManager,
          tempDir: tempDir,
          peerDeviceId: 'rift-peer',
          transferId: '22222222-2222-4222-8222-222222222223',
          messageId: '23232323-2323-4323-8323-232323232323',
        );
        controlledTransport.blockResume('rift-peer');

        emitTrustedSessionReady(context);
        await controlledTransport.waitForResumeCount('rift-peer', 1);
        final resumeWork = service.resumeWorkForPeerForTesting('rift-peer')!;
        final disposing = service.dispose();
        emitTrustedSessionReady(context);

        expect(controlledTransport.resumeCallsByPeer['rift-peer'], 1);
        controlledTransport.releaseResume('rift-peer');
        await Future.wait([resumeWork, disposing]);

        expect(controlledTransport.resumeCallsByPeer['rift-peer'], 1);
      },
    );

    test('same-peer resume reconciliation is single-flight', () async {
      final controlledTransport = await useControlledResumeTransport();
      final context = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer',
        transferId: '24242424-2424-4424-8424-242424242424',
        messageId: '25252525-2525-4525-8525-252525252525',
      );
      controlledTransport.blockResume('rift-peer');

      emitTrustedSessionReady(context);
      await controlledTransport.waitForResumeCount('rift-peer', 1);
      final resumeWork = service.resumeWorkForPeerForTesting('rift-peer')!;
      emitTrustedSessionReady(context);

      expect(controlledTransport.resumeCallsByPeer['rift-peer'], 1);
      expect(controlledTransport.maxActiveResumeCallsByPeer['rift-peer'], 1);
      controlledTransport.releaseResume('rift-peer');
      await resumeWork;
    });

    test('different peers reconcile resumes independently', () async {
      final controlledTransport = await useControlledResumeTransport();
      final peerA = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer-a',
        transferId: '26262626-2626-4626-8626-262626262626',
        messageId: '27272727-2727-4727-8727-272727272727',
      );
      final peerB = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer-b',
        transferId: '28282828-2828-4828-8828-282828282828',
        messageId: '29292929-2929-4929-8929-292929292929',
      );
      controlledTransport.blockResume('rift-peer-a');
      controlledTransport.blockResume('rift-peer-b');

      emitTrustedSessionReady(peerA);
      emitTrustedSessionReady(peerB);
      await Future.wait([
        controlledTransport.waitForResumeCount('rift-peer-a', 1),
        controlledTransport.waitForResumeCount('rift-peer-b', 1),
      ]);
      final peerAWork = service.resumeWorkForPeerForTesting('rift-peer-a')!;
      final peerBWork = service.resumeWorkForPeerForTesting('rift-peer-b')!;

      expect(controlledTransport.activeResumeCalls, 2);
      expect(controlledTransport.maxActiveResumeCalls, 2);
      controlledTransport.releaseResume('rift-peer-a');
      controlledTransport.releaseResume('rift-peer-b');
      await Future.wait([peerAWork, peerBWork]);
    });

    test('repeated ready events coalesce into one resume rerun', () async {
      final controlledTransport = await useControlledResumeTransport();
      final context = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer',
        transferId: '30303030-3030-4030-8030-303030303030',
        messageId: '31313131-3131-4131-8131-313131313131',
      );
      controlledTransport.blockResume('rift-peer');

      emitTrustedSessionReady(context);
      await controlledTransport.waitForResumeCount('rift-peer', 1);
      final resumeWork = service.resumeWorkForPeerForTesting('rift-peer')!;
      for (var i = 0; i < 20; i++) {
        emitTrustedSessionReady(context);
      }

      expect(controlledTransport.resumeCallsByPeer['rift-peer'], 1);
      controlledTransport.releaseResume('rift-peer');
      await resumeWork;
      expect(controlledTransport.resumeCallsByPeer['rift-peer'], 2);
      expect(controlledTransport.maxActiveResumeCallsByPeer['rift-peer'], 1);
    });

    test('ready event during a failed resume send triggers a rerun', () async {
      final controlledTransport = await useControlledResumeTransport();
      final context = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer',
        transferId: '36363636-3636-4636-8636-363636363636',
        messageId: '37373737-3737-4737-8737-373737373737',
      );
      controlledTransport.blockResume('rift-peer');
      controlledTransport.failNextResume('rift-peer');

      emitTrustedSessionReady(context);
      await controlledTransport.waitForResumeCount('rift-peer', 1);
      final resumeWork = service.resumeWorkForPeerForTesting('rift-peer')!;
      emitTrustedSessionReady(context);
      controlledTransport.releaseResume('rift-peer');
      await resumeWork;

      expect(controlledTransport.resumeCallsByPeer['rift-peer'], 2);
      expect(controlledTransport.maxActiveResumeCallsByPeer['rift-peer'], 1);
    });

    test('resume failure is observed and allows a later retry', () async {
      final controlledTransport = await useControlledResumeTransport();
      final context = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer',
        transferId: '32323232-3232-4232-8232-323232323232',
        messageId: '33333333-3333-4333-8333-333333333333',
      );
      controlledTransport.blockResume('rift-peer');
      controlledTransport.failNextResume('rift-peer');

      emitTrustedSessionReady(context);
      await controlledTransport.waitForResumeCount('rift-peer', 1);
      final failedWork = service.resumeWorkForPeerForTesting('rift-peer')!;
      controlledTransport.releaseResume('rift-peer');
      await failedWork;

      expect(service.resumeWorkForPeerForTesting('rift-peer'), isNull);

      emitTrustedSessionReady(context);
      await controlledTransport.waitForResumeCount('rift-peer', 2);
      final retryWork = service.resumeWorkForPeerForTesting('rift-peer');
      if (retryWork != null) await retryWork;

      expect(service.resumeWorkForPeerForTesting('rift-peer'), isNull);
      expect(controlledTransport.resumeCallsByPeer['rift-peer'], 2);
      expect(controlledTransport.maxActiveResumeCallsByPeer['rift-peer'], 1);
    });

    test('dispose waits for owned resume work', () async {
      final controlledTransport = await useControlledResumeTransport();
      final context = await _addResumableIncomingTransfer(
        service: service,
        transport: controlledTransport,
        sessionManager: sessionManager,
        tempDir: tempDir,
        peerDeviceId: 'rift-peer',
        transferId: '34343434-3434-4434-8434-343434343434',
        messageId: '35353535-3535-4535-8535-353535353535',
      );
      controlledTransport.blockResume('rift-peer');

      emitTrustedSessionReady(context);
      await controlledTransport.waitForResumeCount('rift-peer', 1);
      final resumeWork = service.resumeWorkForPeerForTesting('rift-peer')!;
      var disposalCompleted = false;
      final disposing = service.dispose().whenComplete(() {
        disposalCompleted = true;
      });
      final microtaskBarrier = Completer<void>();
      scheduleMicrotask(microtaskBarrier.complete);
      await microtaskBarrier.future;

      expect(disposalCompleted, isFalse);
      controlledTransport.releaseResume('rift-peer');
      await Future.wait([resumeWork, disposing]);
      expect(disposalCompleted, isTrue);
    });

    test('dispose is idempotent while subscriptions are active', () async {
      await useControlledResumeTransport();

      final firstDispose = service.dispose();
      final secondDispose = service.dispose();

      expect(identical(firstDispose, secondDispose), isTrue);
      await Future.wait([firstDispose, secondDispose]);
    });
  });
}
