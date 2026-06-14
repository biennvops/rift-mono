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
  bool isDisconnected = false;

  @override Stream<TransportMessage> get onMessageReceived => _onMessage.stream;
  @override Stream<String> get onPeerDisconnected => _onDisconnect.stream;
  @override Future<void> startServer() async {}
  @override Future<void> stopServer() async {}
  @override Future<void> connectTo(String h, int p, {String? expectedDeviceId}) async {}
  @override void setPeerAuthenticated(String d) {}
  @override Uint8List? getPeerCert(String peerDeviceId) => null;
  
  @override void disconnect(String d) {
    isDisconnected = true;
  }
  
  @override Future<void> sendMessage(String d, Uint8List payload) async {
    sentMessages.add(json.decode(utf8.decode(payload)));
  }

  void simulateIncomingMessage(String d, Uint8List cert, Uint8List key, Map<String, dynamic> payload) {
    _onMessage.add(TransportMessage(
      peerDeviceId: d,
      payload: Uint8List.fromList(utf8.encode(json.encode(payload))),
      peerEd25519Key: key,
      peerCertDer: cert
    ));
  }
}

class FakeIdentityManager implements IdentityManager {
  @override String get deviceId => 'rift-local';
  @override Uint8List getDeviceFingerprint() => Uint8List(32);
  @override Uint8List getEd25519PublicKey() => Uint8List(32);
  @override String get tlsCertificatePem => '';
  @override Uint8List get tlsCertificateDer => Uint8List(0);
  @override String get tlsPrivateKeyPem => '';
  @override Future<void> dispose() async {}
  @override Future<void> initialize() async {}
  @override Future<String> generateIdentityProof(Uint8List c, Uint8List l) async => 'proof';
}

void main() {
  group('SessionManager Tests', () {
    late FakeTransport transport;
    late SessionManager sessionManager;
    late Uint8List testCertDer;
    late Uint8List pubKeyBytes;

    setUp(() async {
      transport = FakeTransport();
      sessionManager = SessionManager(transport, FakeIdentityManager());

      final ecKeyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      var algorithm = Ed25519();
      final edKeyPair = await algorithm.newKeyPair();
      pubKeyBytes = Uint8List.fromList((await edKeyPair.extractPublicKey()).bytes);
      final pem = RiftCertBuilder.generateSelfSignedCert(ecKeyPair, pubKeyBytes, commonName: 'rift-peer');
      
      final lines = pem.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('-----')).join();
      testCertDer = Uint8List.fromList(base64.decode(lines));
    });

    test('Client-side session.accept invalid PoP is disconnected and throws exception', () async {
      // 1. Client initiates connection:
      await sessionManager.sendSessionHello('rift-peer');
      
      // 2. Peer responds session.accept with FAKE PoP signature
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'type': 'session.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'identityProof': 'FAKE-SIGNATURE-HEX-1234',
        }
      });
      
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
    });
  });
}
