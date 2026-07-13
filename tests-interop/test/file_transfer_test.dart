import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/pop_manager.dart';
import 'package:daemon_dart/src/file_transfer/file_transfer_service.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/operation/operation_manager.dart';
import 'package:test/test.dart';

class FakeTrustStore implements TrustStore {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> upsertPeer(PeerRecord record) async {}

  @override
  Future<PeerRecord?> getPeer(String deviceId) async => PeerRecord(
        deviceId: deviceId,
        certDer: Uint8List(0),
        state: TrustState.trusted,
        updatedAt: DateTime.now(),
        lastSeenAt: DateTime.now(),
      );

  @override
  Future<List<PeerRecord>> getPeersByState(TrustState state) async => [];

  @override
  Future<bool> transitionState(
    String deviceId,
    TrustState from,
    TrustState to, {
    DateTime? pairedAt,
  }) async => true;

  @override
  Future<void> deletePeer(String deviceId) async {}

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}

  @override
  Future<void> appendSecurityEvent(SecurityEventRecord record) async {}

  @override
  Future<List<SecurityEventRecord>> querySecurityEvents(
    SecurityEventQuery query,
  ) async => [];

  @override
  Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;
}

class FakeTransport implements Transport {
  final _onMessage = StreamController<TransportMessage>.broadcast();
  final _onDisconnect = StreamController<String>.broadcast();
  final _sentMessagesController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get onSentMessage =>
      _sentMessagesController.stream;

  final List<Map<String, dynamic>> sentMessages = [];
  final Map<String, Uint8List> _peerCerts = {};

  @override
  Stream<TransportMessage> get onMessageReceived => _onMessage.stream;

  @override
  Stream<String> get onPeerDisconnected => _onDisconnect.stream;

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {}

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async => expectedDeviceId ?? 'rift-peer';

  @override
  void setPeerAuthenticated(String peerDeviceId) {}

  @override
  Uint8List? getPeerCert(String peerDeviceId) => _peerCerts[peerDeviceId];

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) => null;

  @override
  void disconnect(String peerDeviceId) {
    if (!_onDisconnect.isClosed) {
      _onDisconnect.add(peerDeviceId);
    }
  }

  @override
  Future<void> sendMessage(String peerDeviceId, Uint8List payload) async {
    final decoded = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    sentMessages.add(decoded);
    if (!_sentMessagesController.isClosed) {
      _sentMessagesController.add(decoded);
    }
  }

  void simulateIncomingMessage(
    String peerDeviceId,
    Uint8List cert,
    Uint8List key,
    Map<String, dynamic> payload,
  ) {
    _peerCerts[peerDeviceId] = cert;
    if (!_onMessage.isClosed) {
      _onMessage.add(
        TransportMessage(
          peerDeviceId: peerDeviceId,
          payload: Uint8List.fromList(utf8.encode(json.encode(payload))),
          peerEd25519Key: key,
          peerCertDer: cert,
        ),
      );
    }
  }

  void registerPeerCert(String peerDeviceId, Uint8List cert) {
    _peerCerts[peerDeviceId] = cert;
  }

  void dispose() {
    _onMessage.close();
    _onDisconnect.close();
    _sentMessagesController.close();
  }
}

class FakeIdentityManager implements IdentityManager {
  final String _deviceId;
  final SimpleKeyPair _keyPair;
  final Uint8List _testCertDer;
  late final Uint8List _pubKey;
  late final Uint8List _privKey;

  FakeIdentityManager(this._deviceId, this._keyPair, this._testCertDer);

  Future<void> initKeys() async {
    _pubKey = Uint8List.fromList((await _keyPair.extractPublicKey()).bytes);
    _privKey = Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());
  }

  @override
  String get deviceId => _deviceId;
  @override
  String get displayName => 'Interop Device $_deviceId';

  @override
  Uint8List getDeviceFingerprint() => Uint8List(32);

  @override
  Uint8List getEd25519PublicKey() => _pubKey;

  @override
  String get tlsCertificatePem => '';

  @override
  Uint8List get tlsCertificateDer => _testCertDer;

  @override
  String get tlsPrivateKeyPem => '';

  @override
  Future<void> dispose() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<String> generateIdentityProof(Uint8List c, Uint8List l) async {
    return PoPManager.generateIdentityProof(c, _pubKey, l, _privKey);
  }
}

void main() {
  group('Simulated File Transfer E2E', () {
    late FakeTransport transport1;
    late FakeTransport transport2;
    late SessionManager sessionManager1;
    late SessionManager sessionManager2;
    late OperationManager operationManager1;
    late OperationManager operationManager2;
    late FileTransferService service1;
    late FileTransferService service2;
    late Directory tempDir1;
    late Directory tempDir2;

    late Uint8List testCertDer1;
    late Uint8List pubKeyBytes1;
    late Uint8List testCertDer2;
    late Uint8List pubKeyBytes2;

    setUp(() async {
      transport1 = FakeTransport();
      transport2 = FakeTransport();

      final ecKeyPair1 = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      final edKeyPair1 = await Ed25519().newKeyPair();
      pubKeyBytes1 = Uint8List.fromList(
        (await edKeyPair1.extractPublicKey()).bytes,
      );
      final pem1 = RiftCertBuilder.generateSelfSignedCert(
        ecKeyPair1,
        pubKeyBytes1,
        commonName: 'rift-device1',
      );
      testCertDer1 = Uint8List.fromList(
        base64.decode(
          pem1
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty && !line.startsWith('-----'))
              .join(),
        ),
      );

      final ecKeyPair2 = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      final edKeyPair2 = await Ed25519().newKeyPair();
      pubKeyBytes2 = Uint8List.fromList(
        (await edKeyPair2.extractPublicKey()).bytes,
      );
      final pem2 = RiftCertBuilder.generateSelfSignedCert(
        ecKeyPair2,
        pubKeyBytes2,
        commonName: 'rift-device2',
      );
      testCertDer2 = Uint8List.fromList(
        base64.decode(
          pem2
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty && !line.startsWith('-----'))
              .join(),
        ),
      );

      final identity1 = FakeIdentityManager(
        'rift-device1',
        edKeyPair1,
        testCertDer1,
      );
      await identity1.initKeys();
      final identity2 = FakeIdentityManager(
        'rift-device2',
        edKeyPair2,
        testCertDer2,
      );
      await identity2.initKeys();

      sessionManager1 = SessionManager(
        transport1,
        identity1,
        FakeTrustStore(),
        peerAllowanceResolver: (_) async => true,
      );
      sessionManager2 = SessionManager(
        transport2,
        identity2,
        FakeTrustStore(),
        peerAllowanceResolver: (_) async => true,
      );

      operationManager1 = OperationManager();
      operationManager2 = OperationManager();
      tempDir1 = await Directory.systemTemp.createTemp('rift-interop-send');
      tempDir2 = await Directory.systemTemp.createTemp('rift-interop-recv');

      service1 = FileTransferService(
        sessionManager: sessionManager1,
        trustStore: FakeTrustStore(),
        operationManager: operationManager1,
        localDeviceId: 'rift-device1',
        storagePath: tempDir1.path,
      );
      service2 = FileTransferService(
        sessionManager: sessionManager2,
        trustStore: FakeTrustStore(),
        operationManager: operationManager2,
        localDeviceId: 'rift-device2',
        storagePath: tempDir2.path,
      );

      transport1.registerPeerCert('rift-device2', testCertDer2);
      transport2.registerPeerCert('rift-device1', testCertDer1);
    });

    Future<void> establishSession() async {
      await sessionManager1.sendSessionHello('rift-device2');
      final helloFrom1 = Map<String, dynamic>.from(
        transport1.sentMessages.removeLast(),
      );

      await sessionManager2.sendSessionHello('rift-device1');
      final helloFrom2 = Map<String, dynamic>.from(
        transport2.sentMessages.removeLast(),
      );

      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        helloFrom1,
      );
      await Future<void>.delayed(Duration.zero);
      final acceptFrom2 = Map<String, dynamic>.from(
        transport2.sentMessages.removeLast(),
      );

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        helloFrom2,
      );
      await Future<void>.delayed(Duration.zero);
      final acceptFrom1 = Map<String, dynamic>.from(
        transport1.sentMessages.removeLast(),
      );

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        acceptFrom2,
      );
      await Future<void>.delayed(Duration.zero);
      final advertiseFrom1 = Map<String, dynamic>.from(
        transport1.sentMessages.removeLast(),
      );

      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        acceptFrom1,
      );
      await Future<void>.delayed(Duration.zero);
      final advertiseFrom2 = Map<String, dynamic>.from(
        transport2.sentMessages.removeLast(),
      );

      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        advertiseFrom1,
      );
      await Future<void>.delayed(Duration.zero);
      final selectedFrom2 = Map<String, dynamic>.from(
        transport2.sentMessages.removeLast(),
      );

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        advertiseFrom2,
      );
      await Future<void>.delayed(Duration.zero);
      final selectedFrom1 = Map<String, dynamic>.from(
        transport1.sentMessages.removeLast(),
      );

      final wait1 = sessionManager1.waitForSessionEstablished('rift-device2');
      final wait2 = sessionManager2.waitForSessionEstablished('rift-device1');

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        selectedFrom2,
      );
      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        selectedFrom1,
      );

      await Future.wait([wait1, wait2]);

      transport1.onSentMessage.listen((message) {
        Future<void>.delayed(Duration.zero, () {
          transport2.simulateIncomingMessage(
            'rift-device1',
            testCertDer1,
            pubKeyBytes1,
            message,
          );
        });
      });
      transport2.onSentMessage.listen((message) {
        Future<void>.delayed(Duration.zero, () {
          transport1.simulateIncomingMessage(
            'rift-device2',
            testCertDer2,
            pubKeyBytes2,
            message,
          );
        });
      });
    }

    tearDown(() async {
      await service1.dispose();
      await service2.dispose();
      operationManager1.dispose();
      operationManager2.dispose();
      await sessionManager1.dispose();
      await sessionManager2.dispose();
      transport1.dispose();
      transport2.dispose();
      if (await tempDir1.exists()) {
        await tempDir1.delete(recursive: true);
      }
      if (await tempDir2.exists()) {
        await tempDir2.delete(recursive: true);
      }
    });

    test('offer accept chunk complete writes verified file to destination', () async {
      await establishSession();

      final sourceFile = File(
        '${tempDir1.path}${Platform.pathSeparator}hello.txt',
      );
      const sourceContent =
          'Hello from simulated daemon-to-daemon file transfer.';
      await sourceFile.writeAsString(sourceContent);
      final expectedHash = sha256.convert(utf8.encode(sourceContent)).toString();

      final fileOfferFuture = service2.onFileOffer.first.timeout(
        const Duration(seconds: 5),
      );

      final offerResult = await service1.offerFile(
        targetDeviceId: 'rift-device2',
        localPath: sourceFile.path,
      );

      final fileOffer = await fileOfferFuture;
      expect(fileOffer['transferId'], offerResult.transferId);
      expect(fileOffer['fileName'], 'hello.txt');

      final completedFuture = service2.onTransferCompleted.first.timeout(
        const Duration(seconds: 5),
      );
      final destinationPath =
          '${tempDir2.path}${Platform.pathSeparator}received-hello.txt';

      final acceptResult = await service2.acceptFileOffer(
        transferId: offerResult.transferId,
        destinationPath: destinationPath,
        overwrite: false,
      );

      expect(acceptResult.transferId, offerResult.transferId);

      final completed = await completedFuture;
      final destinationFile = File(destinationPath);

      expect(completed['transferId'], offerResult.transferId);
      expect(await destinationFile.exists(), isTrue);
      expect(await destinationFile.readAsString(), sourceContent);
      expect(
        sha256.convert(await destinationFile.readAsBytes()).toString(),
        expectedHash,
      );
      expect(
        operationManager1.getOperation(offerResult.operationId).state.wireName,
        'done',
      );
      expect(
        operationManager2.getOperation(acceptResult.operationId).state.wireName,
        'done',
      );
    });
  });
}
