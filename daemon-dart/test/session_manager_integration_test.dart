import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/network/transport_impl.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/pop_manager.dart';
import 'package:basic_utils/basic_utils.dart';
import 'dart:async';
import 'package:daemon_dart/src/interfaces/trust_store.dart';

class FakeTrustStore implements TrustStore {
  final Map<String, PeerRecord> peers = {};

  @override Future<void> initialize() async {}
  @override Future<void> upsertPeer(PeerRecord record) async {
    peers[record.deviceId] = record.copy();
  }
  @override Future<PeerRecord?> getPeer(String deviceId) async => peers[deviceId]?.copy();
  @override Future<List<PeerRecord>> getAllPeers() async => peers.values.map((peer) => peer.copy()).toList();
  @override Future<List<PeerRecord>> getPeersByState(TrustState state) async => peers.values.where((peer) => peer.state == state).map((peer) => peer.copy()).toList();
  @override Future<bool> transitionState(String deviceId, TrustState from, TrustState to, {DateTime? pairedAt}) async => true;
  @override Future<void> deletePeer(String deviceId) async {
    peers.remove(deviceId);
  }
  @override Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}
  @override Future<void> appendSecurityEvent(SecurityEventRecord record) async {}
  @override Future<List<SecurityEventRecord>> querySecurityEvents(SecurityEventQuery query) async => [];
  @override Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;
}

class FakeTransport implements Transport {
  final _onMessage = StreamController<TransportMessage>.broadcast();
  final _onDisconnect = StreamController<String>.broadcast();
  final _sentMessagesController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSentMessage => _sentMessagesController.stream;

  final List<Map<String, dynamic>> sentMessages = [];
  final List<String> disconnectedPeers = [];
  bool isDisconnected = false;
  final Map<String, Uint8List> _peerCerts = {};

  @override Stream<TransportMessage> get onMessageReceived => _onMessage.stream;
  @override Stream<String> get onPeerDisconnected => _onDisconnect.stream;
  @override Future<void> startServer() async {}
  @override Future<void> stopServer() async {}
  @override
  Future<String> connectTo(
    String h,
    int p, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async => expectedDeviceId ?? 'rift-peer';
  @override void setPeerAuthenticated(String d) {}
  @override Uint8List? getPeerCert(String peerDeviceId) => _peerCerts[peerDeviceId];
  @override PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) => null;
  
  @override void disconnect(String d) {
    isDisconnected = true;
    disconnectedPeers.add(d);
    _onDisconnect.add(d);
  }
  
  @override Future<void> sendMessage(String d, Uint8List payload) async {
    final msg = json.decode(utf8.decode(payload));
    sentMessages.add(msg);
    _sentMessagesController.add(msg);
  }

  void simulateIncomingMessage(String d, Uint8List cert, Uint8List key, Map<String, dynamic> payload) {
    _peerCerts[d] = cert;
    _onMessage.add(TransportMessage(
      peerDeviceId: d,
      payload: Uint8List.fromList(utf8.encode(json.encode(payload))),
      peerEd25519Key: key,
      peerCertDer: cert
    ));
  }

  void simulateNetworkDrop(String d) {
    _onDisconnect.add(d);
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
  final String _displayName;
  late final Uint8List _pubKey;
  late final Uint8List _privKey;

  FakeIdentityManager(
    this._deviceId,
    this._keyPair,
    this._testCertDer,
    this._displayName,
  );

  Future<void> initKeys() async {
    _pubKey = Uint8List.fromList((await _keyPair.extractPublicKey()).bytes);
    _privKey = Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());
  }

  @override String get deviceId => _deviceId;
  @override String get displayName => _displayName;
  @override Uint8List getDeviceFingerprint() => Uint8List(32);
  @override Uint8List getEd25519PublicKey() => _pubKey;
  @override String get tlsCertificatePem => '';
  @override Uint8List get tlsCertificateDer => _testCertDer;
  @override String get tlsPrivateKeyPem => '';
  @override Future<void> dispose() async {}
  @override Future<void> initialize() async {}
  @override Future<String> generateIdentityProof(Uint8List c, Uint8List l) async {
    return PoPManager.generateIdentityProof(c, _pubKey, l, _privKey);
  }
}

void main() {
  test('duplicate connection retains an authenticated session', () {
    expect(
      TransportImpl.retainExistingSessionOnDuplicate(isAuthenticated: true),
      isTrue,
    );
    expect(
      TransportImpl.retainExistingSessionOnDuplicate(isAuthenticated: false),
      isFalse,
    );
  });

  group('Session Manager Integration Tests', () {
    late FakeTransport transport1;
    late FakeTransport transport2;
    late SessionManager sessionManager1;
    late SessionManager sessionManager2;
    late FakeTrustStore trustStore1;
    late FakeTrustStore trustStore2;

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

      final fm1 = FakeIdentityManager(
        'rift-device1',
        edKeyPair1,
        testCertDer1,
        'Device One',
      );
      await fm1.initKeys();
      final fm2 = FakeIdentityManager(
        'rift-device2',
        edKeyPair2,
        testCertDer2,
        'Device Two',
      );
      await fm2.initKeys();
      trustStore1 = FakeTrustStore();
      trustStore2 = FakeTrustStore();

      sessionManager1 = SessionManager(
        transport1,
        fm1,
        trustStore1,
        peerAllowanceResolver: (_) async => true,
      );
      sessionManager2 = SessionManager(
        transport2,
        fm2,
        trustStore2,
        peerAllowanceResolver: (_) async => true,
      );
    });

    tearDown(() async {
      await sessionManager1.dispose();
      await sessionManager2.dispose();
      transport1.dispose();
      transport2.dispose();
    });

    test('Simulated Network Drop - cleans up session and fires callbacks', () async {
      // Setup session state
      transport1.registerPeerCert('rift-device2', testCertDer2);

      final disconnectedFuture = transport1.onPeerDisconnected.first;

      // Simulate network drop directly from transport
      transport1.simulateNetworkDrop('rift-device2');
      await disconnectedFuture;

      expect(
        () => sessionManager1.sendMessage('rift-device2', {}),
        throwsA(isA<SessionException>()),
      );
    });
    
    test('Unauthenticated session metadata is not persisted', () async {
      transport1.registerPeerCert('rift-device2', testCertDer2);

      await sessionManager1.sendSessionHello('rift-device2');
      final helloMsg = Map<String, dynamic>.from(transport1.sentMessages.last);
      final payload = Map<String, dynamic>.from(helloMsg['payload'] as Map)
        ..['displayName'] = 'Spoofed Device'
        ..['identityProof'] = List.filled(128, '0').join();
      helloMsg['payload'] = payload;

      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        helloMsg,
      );
      await Future<void>.delayed(Duration.zero);

      expect(await trustStore2.getPeer('rift-device1'), isNull);
      expect(transport2.isDisconnected, isTrue);
    });

    test('Untrusted device.metadata does not update the trust store', () async {
      sessionManager1.injectContextForTesting(
        SessionContext(peerDeviceId: 'rift-device2', isInitiator: true)
          ..handshakeState = HandshakeState.established
          ..capabilityNegotiated = true
          ..trustState = TrustState.discovered,
      );

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        {
          'rift': '0.1-draft',
          'messageId': '33333333-3333-4333-8333-333333333333',
          'type': 'device.metadata',
          'sourceDeviceId': 'rift-device2',
          'destinationDeviceId': 'rift-device1',
          'payload': {'displayName': 'Untrusted Device', 'platform': 'ios'},
        },
      );
      await Future<void>.delayed(Duration.zero);

      expect(await trustStore1.getPeer('rift-device2'), isNull);
    });

    test('Integration test for full session establishment and capability negotiation', () async {
      transport1.registerPeerCert('rift-device2', testCertDer2);
      
      // Send Hello manually (simulating the start of session from discovery)
      await sessionManager1.sendSessionHello('rift-device2');
      
      // Since they aren't fully wired synchronously, we capture the sent message and pass it to transport2 manually
      expect(transport1.sentMessages.isNotEmpty, isTrue);
      final helloMsg = transport1.sentMessages.last;
      expect(helloMsg['messageId'], isNotNull);
      expect(helloMsg['payload']['bindingType'], 'app-nonce');
      expect(helloMsg['payload']['implementationId'], 'riftd-dart/0.1.0');
      expect(helloMsg['payload'].containsKey('displayName'), isFalse);
      expect(helloMsg['payload'].containsKey('platform'), isFalse);
      expect(helloMsg['payload']['capabilities'], isA<List>());
      expect(
        base64.decode(helloMsg['payload']['sessionNonce'] as String),
        hasLength(32),
      );
      
      // We expect transport2 to respond with accept when it receives the hello
      final acceptFuture = transport2.onSentMessage.first;
      transport2.simulateIncomingMessage('rift-device1', testCertDer1, pubKeyBytes1, helloMsg);
      
      final acceptMsg = await acceptFuture;
      expect(acceptMsg['type'], 'session.accept');
      expect(acceptMsg['messageId'], isNotNull);
      expect(acceptMsg['payload']['bindingType'], 'app-nonce');
      expect(acceptMsg['payload'].containsKey('displayName'), isFalse);
      expect(acceptMsg['payload'].containsKey('platform'), isFalse);
      expect(acceptMsg['payload']['capabilities'], isA<List>());
      expect(
        base64.decode(acceptMsg['payload']['sessionNonce'] as String),
        hasLength(32),
      );
      
      expect((await trustStore2.getPeer('rift-device1'))?.displayName, isNull);

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        acceptMsg,
      );
      await Future<void>.delayed(Duration.zero);
      expect((await trustStore1.getPeer('rift-device2'))?.displayName, isNull);

      // Discovery flow and session establish complete.
      expect(transport1.isDisconnected, isFalse);
    });

    test('Bidirectional handshake completes capability negotiation and allows message exchange', () async {
      transport1.registerPeerCert('rift-device2', testCertDer2);
      transport2.registerPeerCert('rift-device1', testCertDer1);

      await sessionManager1.sendSessionHello('rift-device2');
      final helloFrom1 = Map<String, dynamic>.from(transport1.sentMessages.removeLast());

      await sessionManager2.sendSessionHello('rift-device1');
      final helloFrom2 = Map<String, dynamic>.from(transport2.sentMessages.removeLast());

      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        helloFrom1,
      );
      await Future<void>.delayed(Duration.zero);
      final acceptFrom2 = Map<String, dynamic>.from(transport2.sentMessages.removeLast());

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        helloFrom2,
      );
      await Future<void>.delayed(Duration.zero);
      final acceptFrom1 = Map<String, dynamic>.from(transport1.sentMessages.removeLast());

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        acceptFrom2,
      );
      await Future<void>.delayed(Duration.zero);
      final advertiseFrom1 = Map<String, dynamic>.from(transport1.sentMessages.removeLast());

      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        acceptFrom1,
      );
      await Future<void>.delayed(Duration.zero);
      final advertiseFrom2 = Map<String, dynamic>.from(transport2.sentMessages.removeLast());

      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        advertiseFrom1,
      );
      await Future<void>.delayed(Duration.zero);
      final selectedFrom2 = Map<String, dynamic>.from(transport2.sentMessages.removeLast());

      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        advertiseFrom2,
      );
      await Future<void>.delayed(Duration.zero);
      final selectedFrom1 = Map<String, dynamic>.from(transport1.sentMessages.removeLast());

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

      final ctx1 = sessionManager1.getContext('rift-device2');
      final ctx2 = sessionManager2.getContext('rift-device1');

      expect(ctx1, isNotNull);
      expect(ctx2, isNotNull);
      expect(ctx1!.handshakeState, HandshakeState.established);
      expect(ctx2!.handshakeState, HandshakeState.established);
      expect(ctx1.capabilityNegotiated, isTrue);
      expect(ctx2.capabilityNegotiated, isTrue);
      expect(
        ctx1.negotiatedCapabilities.map((c) => c.name),
        containsAll(<String>[
          'clipboard.offer_fetch',
          'file.transfer',
          'presence.basic',
          'operation.lifecycle',
          'security.event_log',
        ]),
      );
      expect(
        ctx2.negotiatedCapabilities.map((c) => c.name),
        containsAll(<String>[
          'clipboard.offer_fetch',
          'file.transfer',
          'presence.basic',
          'operation.lifecycle',
          'security.event_log',
        ]),
      );

      final receivedFuture = sessionManager2.onMessage.first;
      await sessionManager1.sendMessage('rift-device2', {
        'rift': '0.1-draft',
        'messageId': '77777777-7777-4777-8777-777777777777',
        'type': 'operation.test',
        'sourceDeviceId': 'rift-device1',
        'destinationDeviceId': 'rift-device2',
        'payload': {
          'value': 'hello-from-device1',
        },
      });

      final delivered = Map<String, dynamic>.from(transport1.sentMessages.removeLast());
      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        delivered,
      );

      final received = await receivedFuture;
      expect(received.peerDeviceId, 'rift-device1');
      expect(received.payload['type'], 'operation.test');
      expect(received.payload['payload']['value'], 'hello-from-device1');
    });

    test('Trusted sequential handshake synchronizes metadata in both directions', () async {
      await trustStore1.upsertPeer(
        PeerRecord(
          deviceId: 'rift-device2',
          displayName: 'Old Device Two',
          platform: 'unknown',
          certDer: testCertDer2,
          state: TrustState.trusted,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      await trustStore2.upsertPeer(
        PeerRecord(
          deviceId: 'rift-device1',
          displayName: 'Old Device One',
          platform: 'unknown',
          certDer: testCertDer1,
          state: TrustState.trusted,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      transport1.registerPeerCert('rift-device2', testCertDer2);
      transport2.registerPeerCert('rift-device1', testCertDer1);
      final metadataFrom1Future = transport1.onSentMessage.firstWhere(
        (msg) => msg['type'] == 'device.metadata',
      );
      final metadataFrom2Future = transport2.onSentMessage.firstWhere(
        (msg) => msg['type'] == 'device.metadata',
      );

      final advertiseFrom2Future = transport2.onSentMessage.firstWhere(
        (msg) => msg['type'] == 'capability.advertise',
      );

      await sessionManager1.sendSessionHello('rift-device2');
      final helloFrom1 = Map<String, dynamic>.from(transport1.sentMessages.removeLast());

      final acceptFuture = transport2.onSentMessage.firstWhere((msg) => msg['type'] == 'session.accept');
      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        helloFrom1,
      );
      final acceptFrom2 = Map<String, dynamic>.from(await acceptFuture);

      // Initiator will start capability negotiation after receiving accept.
      final advertiseFrom1Future = transport1.onSentMessage.firstWhere(
        (msg) => msg['type'] == 'capability.advertise',
      );

      // Deliver accept back to device1.
      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        acceptFrom2,
      );
      final advertiseFrom1 = Map<String, dynamic>.from(await advertiseFrom1Future);
      final advertiseFrom2 = Map<String, dynamic>.from(await advertiseFrom2Future);

      // Exchange capability.advertise.
      final selectedFrom1Future = transport1.onSentMessage.firstWhere(
        (msg) => msg['type'] == 'capability.selected',
      );
      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        advertiseFrom1,
      );
      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        advertiseFrom2,
      );
      final selectedFrom1 = Map<String, dynamic>.from(await selectedFrom1Future);

      final wait1 = sessionManager1.waitForSessionEstablished('rift-device2');
      final wait2 = sessionManager2.waitForSessionEstablished('rift-device1');

      // Initiator (device1) sends capability.selected; responder (device2) completes on receipt.
      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        selectedFrom1,
      );

      await Future.wait([wait1, wait2]);

      final ctx1 = sessionManager1.getContext('rift-device2');
      final ctx2 = sessionManager2.getContext('rift-device1');
      expect(ctx1, isNotNull);
      expect(ctx2, isNotNull);
      expect(ctx1!.handshakeState, HandshakeState.established);
      expect(ctx2!.handshakeState, HandshakeState.established);
      expect(ctx1.capabilityNegotiated, isTrue);
      expect(ctx2.capabilityNegotiated, isTrue);

      final metadataFrom1 = Map<String, dynamic>.from(await metadataFrom1Future);
      final metadataFrom2 = Map<String, dynamic>.from(await metadataFrom2Future);
      transport1.simulateIncomingMessage(
        'rift-device2',
        testCertDer2,
        pubKeyBytes2,
        metadataFrom2,
      );
      transport2.simulateIncomingMessage(
        'rift-device1',
        testCertDer1,
        pubKeyBytes1,
        metadataFrom1,
      );
      await Future<void>.delayed(Duration.zero);

      expect((await trustStore1.getPeer('rift-device2'))?.displayName, 'Device Two');
      expect((await trustStore2.getPeer('rift-device1'))?.displayName, 'Device One');
    });
  });
}
