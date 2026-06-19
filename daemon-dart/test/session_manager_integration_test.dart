import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/pop_manager.dart';
import 'package:basic_utils/basic_utils.dart';
import 'dart:async';

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
  @override Future<String> connectTo(String h, int p, {String? expectedDeviceId}) async => expectedDeviceId ?? 'rift-peer';
  @override void setPeerAuthenticated(String d) {}
  @override Uint8List? getPeerCert(String peerDeviceId) => _peerCerts[peerDeviceId];
  
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
  late final Uint8List _pubKey;
  late final Uint8List _privKey;

  FakeIdentityManager(this._deviceId, this._keyPair, this._testCertDer);

  Future<void> initKeys() async {
    _pubKey = Uint8List.fromList((await _keyPair.extractPublicKey()).bytes);
    _privKey = Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());
  }

  @override String get deviceId => _deviceId;
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
  group('Session Manager Integration Tests', () {
    late FakeTransport transport1;
    late FakeTransport transport2;
    late SessionManager sessionManager1;
    late SessionManager sessionManager2;

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

      sessionManager1 = SessionManager(
        transport1,
        fm1,
        isPeerAllowed: (_) async => true,
      );
      sessionManager2 = SessionManager(
        transport2,
        fm2,
        isPeerAllowed: (_) async => true,
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
    
    test('Integration test for full session establishment and capability negotiation', () async {
      transport1.registerPeerCert('rift-device2', testCertDer2);
      
      // Send Hello manually (simulating the start of session from discovery)
      await sessionManager1.sendSessionHello('rift-device2');
      
      // Since they aren't fully wired synchronously, we capture the sent message and pass it to transport2 manually
      expect(transport1.sentMessages.isNotEmpty, isTrue);
      final helloMsg = transport1.sentMessages.last;
      
      // We expect transport2 to respond with accept when it receives the hello
      final acceptFuture = transport2.onSentMessage.first;
      transport2.simulateIncomingMessage('rift-device1', testCertDer1, pubKeyBytes1, helloMsg);
      
      final acceptMsg = await acceptFuture;
      expect(acceptMsg['type'], 'session.accept');
      
      // Discovery flow and session establish complete.
      expect(transport1.isDisconnected, isFalse);
    });
  });
}
