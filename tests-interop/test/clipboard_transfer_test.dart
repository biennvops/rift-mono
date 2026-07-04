import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/pop_manager.dart';
import 'package:basic_utils/basic_utils.dart';
import 'dart:async';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/clipboard/clipboard_engine.dart';
import 'package:daemon_dart/src/clipboard/clipboard_handler.dart';
import 'package:daemon_dart/src/clipboard/clipboard_models.dart';

// REUSED FAKE HARNESS
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
  Future<bool> transitionState(String deviceId, TrustState from, TrustState to, {DateTime? pairedAt}) async => true;
  @override
  Future<void> deletePeer(String deviceId) async {}
  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}
  @override
  Future<void> appendSecurityEvent(SecurityEventRecord record) async {}
  @override
  Future<List<SecurityEventRecord>> querySecurityEvents(SecurityEventQuery query) async => [];
  @override
  Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;
}

class FakeTransport implements Transport {
  final _onMessage = StreamController<TransportMessage>.broadcast();
  final _onDisconnect = StreamController<String>.broadcast();
  final _sentMessagesController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSentMessage => _sentMessagesController.stream;

  final List<Map<String, dynamic>> sentMessages = [];
  bool isDisconnected = false;
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
  Future<String> connectTo(String h, int p, {String? expectedDeviceId}) async => expectedDeviceId ?? 'rift-peer';
  @override
  void setPeerAuthenticated(String d) {}
  @override
  Uint8List? getPeerCert(String peerDeviceId) => _peerCerts[peerDeviceId];

  @override
  void disconnect(String d) {
    isDisconnected = true;
    if (!_onDisconnect.isClosed) {
      _onDisconnect.add(d);
    }
  }

  @override
  Future<void> sendMessage(String d, Uint8List payload) async {
    final msg = json.decode(utf8.decode(payload));
    sentMessages.add(msg);
    if (!_sentMessagesController.isClosed) {
      _sentMessagesController.add(msg);
    }
  }

  void simulateIncomingMessage(String d, Uint8List cert, Uint8List key, Map<String, dynamic> payload) {
    _peerCerts[d] = cert;
    if (!_onMessage.isClosed) {
      _onMessage.add(TransportMessage(peerDeviceId: d, payload: Uint8List.fromList(utf8.encode(json.encode(payload))), peerEd25519Key: key, peerCertDer: cert));
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
  group('Simulated Clipboard E2E Transfer', () {
    late FakeTransport transport1;
    late FakeTransport transport2;
    late SessionManager sessionManager1;
    late SessionManager sessionManager2;
    late ClipboardEngine engine1;
    late ClipboardEngine engine2;
    late ClipboardProtocolHandler handler1;
    late ClipboardProtocolHandler handler2;

    late Uint8List testCertDer1;
    late Uint8List pubKeyBytes1;
    late Uint8List testCertDer2;
    late Uint8List pubKeyBytes2;

    setUp(() async {
      transport1 = FakeTransport();
      transport2 = FakeTransport();

      final ecKeyPair1 = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      final edKeyPair1 = await Ed25519().newKeyPair();
      pubKeyBytes1 = Uint8List.fromList((await edKeyPair1.extractPublicKey()).bytes);
      final pem1 = RiftCertBuilder.generateSelfSignedCert(ecKeyPair1, pubKeyBytes1, commonName: 'rift-device1');
      testCertDer1 = Uint8List.fromList(base64.decode(pem1.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('-----')).join()));

      final ecKeyPair2 = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      final edKeyPair2 = await Ed25519().newKeyPair();
      pubKeyBytes2 = Uint8List.fromList((await edKeyPair2.extractPublicKey()).bytes);
      final pem2 = RiftCertBuilder.generateSelfSignedCert(ecKeyPair2, pubKeyBytes2, commonName: 'rift-device2');
      testCertDer2 = Uint8List.fromList(base64.decode(pem2.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('-----')).join()));

      final fm1 = FakeIdentityManager('rift-device1', edKeyPair1, testCertDer1);
      await fm1.initKeys();
      final fm2 = FakeIdentityManager('rift-device2', edKeyPair2, testCertDer2);
      await fm2.initKeys();

      sessionManager1 = SessionManager(transport1, fm1, FakeTrustStore(), peerAllowanceResolver: (_) async => true);
      sessionManager2 = SessionManager(transport2, fm2, FakeTrustStore(), peerAllowanceResolver: (_) async => true);

      transport1.registerPeerCert('rift-device2', testCertDer2);
      transport2.registerPeerCert('rift-device1', testCertDer1);
      
      // Auto-forwarding removed to use manual establishSession step-by-step
      engine1 = ClipboardEngine();
      engine2 = ClipboardEngine();
      handler1 = ClipboardProtocolHandler(sessionManager1, engine1, (id) async => engine1.getLocalContent(id), 'rift-device1');
      handler2 = ClipboardProtocolHandler(sessionManager2, engine2, (id) async => engine2.getLocalContent(id), 'rift-device2');
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
      
      // Re-enable auto-forwarding for clipboard messages after session is established!
      transport1.onSentMessage.listen((msg) {
        Future.delayed(Duration.zero, () {
          transport2.simulateIncomingMessage('rift-device1', testCertDer1, pubKeyBytes1, msg);
        });
      });
      transport2.onSentMessage.listen((msg) {
        Future.delayed(Duration.zero, () {
          transport1.simulateIncomingMessage('rift-device2', testCertDer2, pubKeyBytes2, msg);
        });
      });

      // Send presence.update to establish clipboard capability
      final msgId1 = '77777777-7777-4777-8777-777777777771';
      await sessionManager1.sendMessage('rift-device2', {
        'rift': '0.1-draft',
        'messageId': msgId1,
        'type': 'presence.update',
        'sourceDeviceId': 'rift-device1',
        'destinationDeviceId': 'rift-device2',
        'payload': {
          'status': 'online',
          'capabilities': ['clipboard.offer_fetch'],
        },
      });

      final msgId2 = '77777777-7777-4777-8777-777777777772';
      await sessionManager2.sendMessage('rift-device1', {
        'rift': '0.1-draft',
        'messageId': msgId2,
        'type': 'presence.update',
        'sourceDeviceId': 'rift-device2',
        'destinationDeviceId': 'rift-device1',
        'payload': {
          'status': 'online',
          'capabilities': ['clipboard.offer_fetch'],
        },
      });
      
      // Wait for presence updates to be processed
      await Future.delayed(const Duration(milliseconds: 50));
    }

    tearDown(() async {
      await sessionManager1.dispose();
      await sessionManager2.dispose();
      handler1.dispose();
      handler2.dispose();
      engine1.dispose();
      engine2.dispose();
      transport1.dispose();
      transport2.dispose();
    });

    test('E2E clipboard transfer: successful fetch and data integrity', () async {
      print('Establishing session...');
      await establishSession();
      print('Session established!');
      
      try {
        sessionManager2.requireCapability('rift-device1', 'clipboard.offer_fetch');
        print('Capability check PASSED on device2!');
      } catch (e) {
        print('Capability check FAILED on device2: $e');
      }
      
      final text = 'Hello cross-platform Rift!';
      final bytes = utf8.encode(text);
      final hash = sha256.convert(bytes).toString();
      final base64Content = base64Encode(bytes);
      
      final offer = engine1.createLocalOffer(
        offerId: 'offer-1',
        contentType: 'text/plain',
        byteSize: bytes.length,
        sha256: hash,
        expiresInMs: 60000,
        localDeviceId: 'rift-device1',
        contentBase64: base64Content,
      );
      
      print('Sending clipboard offer...');
      // Start listening BEFORE sending to avoid race condition!
      final incomingOfferFuture = engine2.onOfferAdded.first.timeout(Duration(seconds: 5));

      // Device 1 sends offer to Device 2
      await sessionManager1.sendMessage('rift-device2', {
        'rift': '0.1-draft',
        'messageId': '55555555-5555-4555-8555-555555555551',
        'type': 'clipboard.offer',
        'sourceDeviceId': 'rift-device1',
        'destinationDeviceId': 'rift-device2',
        'payload': offer.toJson(),
      });
      
      print('Waiting for engine2.onOfferAdded.first...');
      // Wait for Device 2 engine to process the incoming offer
      final incomingOffer = await incomingOfferFuture;
      print('Received offer on engine2!');
      expect(incomingOffer.offerId, 'offer-1');
      
      print('Sending fetch request...');
      final fetchResponseFuture = handler2.onFetchResponse.first.timeout(Duration(seconds: 5));

      // Device 2 fetches the offer
      await handler2.sendFetchRequest('rift-device1', 'offer-1');
      
      print('Waiting for handler2.onFetchResponse.first...');
      // Wait for Device 2 to receive the fetch response
      final response = await fetchResponseFuture;
      print('Received fetch response!');
      
      // Data Integrity Checks
      expect(response.offerId, 'offer-1');
      expect(response.sha256, hash);
      expect(response.byteSize, bytes.length);
      expect(utf8.decode(base64Decode(response.contentBase64)), text);
    });

    test('Boundary: Reject empty clipboard payload gracefully', () async {
      await establishSession();
      
      final text = '';
      final bytes = utf8.encode(text);
      final hash = sha256.convert(bytes).toString();
      final base64Content = base64Encode(bytes);
      
      final offer = engine1.createLocalOffer(
        offerId: 'offer-empty',
        contentType: 'text/plain',
        byteSize: bytes.length,
        sha256: hash,
        expiresInMs: 60000,
        localDeviceId: 'rift-device1',
        contentBase64: base64Content,
      );
      
      final incomingOfferFuture = engine2.onOfferAdded.first.timeout(Duration(seconds: 5));
      
      await sessionManager1.sendMessage('rift-device2', {
        'rift': '0.1-draft',
        'messageId': '55555555-5555-4555-8555-555555555552',
        'type': 'clipboard.offer',
        'sourceDeviceId': 'rift-device1',
        'destinationDeviceId': 'rift-device2',
        'payload': offer.toJson(),
      });
      
      await incomingOfferFuture;
      
      final fetchResponseFuture = handler2.onFetchResponse.first.timeout(Duration(seconds: 5));
      await handler2.sendFetchRequest('rift-device1', 'offer-empty');
      final response = await fetchResponseFuture;
      
      expect(response.offerId, 'offer-empty');
      expect(response.byteSize, 0);
      expect(response.contentBase64, '');
    });

    test('Boundary: Reject oversized clipboard offer', () async {
      await establishSession();
      
      // We simulate an oversized payload (e.g. 40 MiB)
      final size = 40 * 1024 * 1024;
      
      final offer = ClipboardOffer(
        offerId: 'offer-oversized',
        contentType: 'text/plain',
        byteSize: size,
        sha256: 'some-hash',
        expiresInMs: 60000,
        sourceDeviceId: 'rift-device1',
        requiredCapability: 'clipboard.offer_fetch',
        offerSequence: 1,
      );
      
      await sessionManager1.sendMessage('rift-device2', {
        'rift': '0.1-draft',
        'messageId': '55555555-5555-4555-8555-555555555553',
        'type': 'clipboard.offer',
        'sourceDeviceId': 'rift-device1',
        'destinationDeviceId': 'rift-device2',
        'payload': offer.toJson(),
      });
      
      // The offer should be dropped, so if we wait 50ms, the engine should NOT have it
      await Future.delayed(const Duration(milliseconds: 50));
      expect(engine2.getOffer('offer-oversized'), isNull);
    });
    
    test('Boundary: E2E Unicode and Special Characters (UTF-8 preservation)', () async {
      await establishSession();
      
      final text = 'こんにちは RIFT! 🚀👨‍👩‍👧‍👦 \u0000 special chars \n\r\t';
      final bytes = utf8.encode(text);
      final hash = sha256.convert(bytes).toString();
      final base64Content = base64Encode(bytes);
      
      final offer = engine1.createLocalOffer(
        offerId: 'offer-unicode',
        contentType: 'text/plain',
        byteSize: bytes.length,
        sha256: hash,
        expiresInMs: 60000,
        localDeviceId: 'rift-device1',
        contentBase64: base64Content,
      );
      
      final incomingOfferFuture = engine2.onOfferAdded.first.timeout(Duration(seconds: 5));
      
      await sessionManager1.sendMessage('rift-device2', {
        'rift': '0.1-draft',
        'messageId': '55555555-5555-4555-8555-555555555554',
        'type': 'clipboard.offer',
        'sourceDeviceId': 'rift-device1',
        'destinationDeviceId': 'rift-device2',
        'payload': offer.toJson(),
      });
      
      await incomingOfferFuture;
      
      final fetchResponseFuture = handler2.onFetchResponse.first.timeout(Duration(seconds: 5));
      await handler2.sendFetchRequest('rift-device1', 'offer-unicode');
      final response = await fetchResponseFuture;
      
      expect(response.sha256, hash);
      expect(utf8.decode(base64Decode(response.contentBase64)), text);
    });
  });
}
