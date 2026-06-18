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
  // Track certs so getPeerCert works once simulateIncomingMessage is called.
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
  }
  
  @override Future<void> sendMessage(String d, Uint8List payload) async {
    sentMessages.add(json.decode(utf8.decode(payload)));
  }

  void simulateIncomingMessage(String d, Uint8List cert, Uint8List key, Map<String, dynamic> payload) {
    _peerCerts[d] = cert; // register so getPeerCert works
    _onMessage.add(TransportMessage(
      peerDeviceId: d,
      payload: Uint8List.fromList(utf8.encode(json.encode(payload))),
      peerEd25519Key: key,
      peerCertDer: cert
    ));
  }

  void simulateIncomingRawPayload(String d, Uint8List cert, Uint8List key, String payload) {
    _peerCerts[d] = cert;
    _onMessage.add(TransportMessage(
      peerDeviceId: d,
      payload: Uint8List.fromList(utf8.encode(payload)),
      peerEd25519Key: key,
      peerCertDer: cert,
    ));
  }

  // Pre-register a cert for a peer before sending session.hello (client-side tests).
  void registerPeerCert(String peerDeviceId, Uint8List cert) {
    _peerCerts[peerDeviceId] = cert;
  }
}

class FakeIdentityManager implements IdentityManager {
  @override String get deviceId => 'rift-local';
  @override Uint8List getDeviceFingerprint() => Uint8List(32);
  @override Uint8List getEd25519PublicKey() => Uint8List(32);
  @override String get tlsCertificatePem => '';
  // Non-empty local cert DER so SHA-256 channel binding produces a real hash.
  @override Uint8List get tlsCertificateDer => Uint8List.fromList(List.generate(64, (i) => i & 0xFF));
  @override String get tlsPrivateKeyPem => '';
  @override Future<void> dispose() async {}
  @override Future<void> initialize() async {}
  @override Future<String> generateIdentityProof(Uint8List c, Uint8List l) async => 'a' * 128;
}

void main() {
  group('SessionManager Tests', () {
    late FakeTransport transport;
    late SessionManager sessionManager;
    late Uint8List testCertDer;
    late Uint8List pubKeyBytes;
    late bool allowPeer;

    setUp(() async {
      transport = FakeTransport();
      allowPeer = true;
      sessionManager = SessionManager(
        transport,
        FakeIdentityManager(),
        isPeerAllowed: (_) async => allowPeer,
      );

      final ecKeyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      var algorithm = Ed25519();
      final edKeyPair = await algorithm.newKeyPair();
      pubKeyBytes = Uint8List.fromList((await edKeyPair.extractPublicKey()).bytes);
      final pem = RiftCertBuilder.generateSelfSignedCert(ecKeyPair, pubKeyBytes, commonName: 'rift-peer');
      
      final lines = pem.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('-----')).join();
      testCertDer = Uint8List.fromList(base64.decode(lines));
    });

    tearDown(() async {
      await sessionManager.dispose();
    });

    test('Client-side session.accept missing identityVerified fails before PoP validation', () async {
      // Register the peer cert BEFORE calling sendSessionHello so the channel
      // binding can be computed (mimics the transport having seen the peer TLS cert).
      transport.registerPeerCert('rift-peer', testCertDer);

      // 1. Client initiates connection:
      await sessionManager.sendSessionHello('rift-peer');
      expect(transport.sentMessages.single['messageId'], isNotNull);
      expect(transport.sentMessages.single['payload']['supportedVersions'], ['0.1-draft']);
      
      // 2. Peer responds session.accept with FAKE PoP signature
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '11111111-1111-4111-8111-111111111111',
        'type': 'session.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'selectedVersion': '0.1-draft',
          'identityProof': 'FAKE-SIGNATURE-HEX-1234',
        }
      });
      
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
    });

    test('Blocked or revoked peer is rejected during session.hello bootstrap', () async {
      allowPeer = false;

      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '22222222-2222-4222-8222-222222222222',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'identityProof': '0' * 128,
        }
      });

      await Future.delayed(Duration.zero);

      expect(transport.isDisconnected, isTrue);
      expect(transport.disconnectedPeers, contains('rift-peer'));
      expect(transport.sentMessages, isNotEmpty);
      expect(transport.sentMessages.single['type'], 'session.reject');
      expect(transport.sentMessages.single['payload']['failureReason'], 'Unauthorized');
    });

    test('session.hello rejects missing supportedVersions', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '33333333-3333-4333-8333-333333333333',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'identityProof': '0' * 128,
        }
      });

      await Future.delayed(Duration.zero);

      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'VersionMismatch');
    });

    test('session.hello rejects payload deviceId mismatch', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '44444444-4444-4444-8444-444444444444',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-other',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [
            {'name': 'clipboard.offer_fetch', 'version': 1},
            {'name': 'presence.basic', 'version': 1},
            {'name': 'operation.lifecycle', 'version': 1},
            {'name': 'security.event_log', 'version': 1},
          ],
          'identityProof': '0' * 128,
        }
      });

      await Future.delayed(Duration.zero);

      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'Unauthorized');
    });

    test('second session.hello on same connection is rejected with ProtocolError', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '55555555-5555-4555-8555-555555555555',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [
            {'name': 'clipboard.offer_fetch', 'version': 1},
            {'name': 'presence.basic', 'version': 1},
            {'name': 'operation.lifecycle', 'version': 1},
            {'name': 'security.event_log', 'version': 1},
          ],
          'identityProof': '0' * 128,
        }
      });
      await Future.delayed(Duration.zero);

      transport.sentMessages.clear();
      transport.isDisconnected = false;

      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '66666666-6666-4666-8666-666666666666',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [
            {'name': 'clipboard.offer_fetch', 'version': 1},
            {'name': 'presence.basic', 'version': 1},
            {'name': 'operation.lifecycle', 'version': 1},
            {'name': 'security.event_log', 'version': 1},
          ],
          'identityProof': '0' * 128,
        }
      });
      await Future.delayed(Duration.zero);

      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'ProtocolError');
    });

    test('sendSessionHello rejects duplicate local hello on same connection', () async {
      // Register peer cert so the first call can compute channel binding.
      transport.registerPeerCert('rift-peer', testCertDer);
      await sessionManager.sendSessionHello('rift-peer');

      await expectLater(
        sessionManager.sendSessionHello('rift-peer'),
        throwsA(isA<SessionException>()),
      );
    });

    test('invalid JSON payload is rejected as malformed message', () async {
      transport.simulateIncomingRawPayload('rift-peer', testCertDer, pubKeyBytes, '{not-json');
      await Future.delayed(Duration.zero);

      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'MalformedMessage');
    });

    test('session.accept rejects missing identityVerified', () async {
      // First, simulate sending session.hello to set the local state to expecting session.accept
      transport.registerPeerCert('rift-peer', testCertDer);
      await sessionManager.sendSessionHello('rift-peer');
      transport.sentMessages.clear();
      transport.isDisconnected = false;

      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        'type': 'session.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'selectedVersion': '0.1-draft',
          'deviceId': 'rift-peer',
          'capabilities': const [],
          'identityProof': '0' * 128,
          'sessionNonce': base64.encode(Uint8List(32)),
          // identityVerified is intentionally omitted
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'ProtocolError');
    });


    test('rejects requiredExtensions if it is not a list', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'requiredExtensions': 'not-a-list', // Invalid type
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'identityProof': '0' * 128,
          'sessionNonce': base64.encode(Uint8List(32)),
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'ProtocolError');
    });
  });
}
