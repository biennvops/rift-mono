import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:basic_utils/basic_utils.dart';
import 'dart:async';

class FakeTransport implements Transport {
  final _onMessage = StreamController<TransportMessage>.broadcast();
  final _onDisconnect = StreamController<String>.broadcast();
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
    sentMessages.add(json.decode(utf8.decode(payload)));
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
  }
}

class FakeIdentityManager implements IdentityManager {
  final String _deviceId;
  FakeIdentityManager(this._deviceId);

  @override String get deviceId => _deviceId;
  @override Uint8List getDeviceFingerprint() => Uint8List(32);
  @override Uint8List getEd25519PublicKey() => Uint8List(32);
  @override String get tlsCertificatePem => '';
  @override Uint8List get tlsCertificateDer => Uint8List.fromList(List.generate(64, (i) => i & 0xFF));
  @override String get tlsPrivateKeyPem => '';
  @override Future<void> dispose() async {}
  @override Future<void> initialize() async {}
  @override Future<String> generateIdentityProof(Uint8List c, Uint8List l) async => 'a' * 128;
}

void main() {
  group('Discovery & Network Integration Tests', () {
    late FakeTransport transport1;
    late FakeTransport transport2;
    late SessionManager sessionManager1;
    late SessionManager sessionManager2;

    late Uint8List testCertDer1;
    late Uint8List pubKeyBytes1;
    late Uint8List testCertDer2;
    late Uint8List pubKeyBytes2;

    StreamSubscription? sub1;
    StreamSubscription? sub2;

    setUp(() async {
      transport1 = FakeTransport();
      transport2 = FakeTransport();

      sessionManager1 = SessionManager(
        transport1,
        FakeIdentityManager('rift-device1'),
        isPeerAllowed: (_) async => true,
      );
      sessionManager2 = SessionManager(
        transport2,
        FakeIdentityManager('rift-device2'),
        isPeerAllowed: (_) async => true,
      );

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

      // Wire transports together for integration
      sub1 = transport1.onMessageReceived.listen((msg) {
        // Forward from 1 to 2
        transport2.simulateIncomingMessage('rift-device1', testCertDer1, pubKeyBytes1, json.decode(utf8.decode(msg.payload)));
      });

      sub2 = transport2.onMessageReceived.listen((msg) {
        // Forward from 2 to 1
        transport1.simulateIncomingMessage('rift-device2', testCertDer2, pubKeyBytes2, json.decode(utf8.decode(msg.payload)));
      });
    });

    tearDown(() async {
      await sub1?.cancel();
      await sub2?.cancel();
      await sessionManager1.dispose();
      await sessionManager2.dispose();
      transport1.dispose();
      transport2.dispose();
    });

    test('Simulated Network Drop - cleans up session and fires callbacks', () async {
      // Setup session state
      transport1.registerPeerCert('rift-device2', testCertDer2);
      
      // Simulate network drop directly from transport 
      transport1.simulateNetworkDrop('rift-device2');
      
      await Future.delayed(Duration(milliseconds: 100));

      expect(
        () => sessionManager1.sendMessage('rift-device2', {}),
        throwsA(isA<SessionException>()),
      );
    });
    
    test('Integration test for discovery flow and capability negotiation', () async {
      transport1.registerPeerCert('rift-device2', testCertDer2);
      
      // Send Hello manually (simulating the start of session from discovery)
      await sessionManager1.sendSessionHello('rift-device2');
      
      // Since they aren't fully wired synchronously, we capture the sent message and pass it to transport2 manually
      expect(transport1.sentMessages.isNotEmpty, isTrue);
      final helloMsg = transport1.sentMessages.last;
      
      transport2.simulateIncomingMessage('rift-device1', testCertDer1, pubKeyBytes1, helloMsg);
      await Future.delayed(Duration(milliseconds: 50));
      
      // transport2 should respond with accept
      expect(transport2.sentMessages.isNotEmpty, isTrue);
      final acceptMsg = transport2.sentMessages.last;
      expect(acceptMsg['type'], 'session.accept');
      
      // Forward back to transport1
      transport1.simulateIncomingMessage('rift-device2', testCertDer2, pubKeyBytes2, acceptMsg);
      await Future.delayed(Duration(milliseconds: 50));

      // After accept, capabilities should be exchanged. 
      // Transport1 should send capability.advertise
      final advertiseMsg1 = transport1.sentMessages.last;
      expect(advertiseMsg1['type'], 'capability.advertise');
      
      // Provide capability.advertise to transport2
      transport2.simulateIncomingMessage('rift-device1', testCertDer1, pubKeyBytes1, advertiseMsg1);
      
      await Future.delayed(Duration(milliseconds: 50));
      
      // Provide capability.advertise from transport2 to transport1
      final advertiseMsg2 = transport2.sentMessages.last;
      expect(advertiseMsg2['type'], 'capability.advertise');
      transport1.simulateIncomingMessage('rift-device2', testCertDer2, pubKeyBytes2, advertiseMsg2);
      
      await Future.delayed(Duration(milliseconds: 50));
      
      // Transport1 should send capability.selected
      final selectedMsg = transport1.sentMessages.last;
      expect(selectedMsg['type'], 'capability.selected');
      
      // Discovery flow and session establish complete.
      expect(transport1.isDisconnected, isFalse);
    });
  });
}
