import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
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

  void simulateNetworkDrop(String peerDeviceId) {
    _onDisconnect.add(peerDeviceId);
  }
}


class FakeTrustStore implements TrustStore {
  @override Future<void> initialize() async {}
  @override Future<void> upsertPeer(PeerRecord record) async {}
  @override Future<PeerRecord?> getPeer(String deviceId) async => null;
  @override Future<List<PeerRecord>> getAllPeers() async => [];
  @override Future<List<PeerRecord>> getPeersByState(TrustState state) async => [];
  @override Future<bool> transitionState(String deviceId, TrustState from, TrustState to, {DateTime? pairedAt}) async => true;
  @override Future<void> deletePeer(String deviceId) async {}
  @override Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}
  @override Future<void> appendSecurityEvent(SecurityEventRecord record) async {}
  @override Future<List<SecurityEventRecord>> querySecurityEvents(SecurityEventQuery query) async => [];
  @override Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;
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
        FakeTrustStore(),
        peerAllowanceResolver: (_) async => allowPeer,
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
      sessionManager.dispose();
    });

    test('Client-side session.accept missing identityVerified fails before PoP validation', () async {
      // Register the peer cert BEFORE calling sendSessionHello so the channel
      // binding can be computed (mimics the transport having seen the peer TLS cert).
      transport.registerPeerCert('rift-peer', testCertDer);

      // 1. Client initiates connection:
      await sessionManager.sendSessionHello('rift-peer');
      expect(transport.sentMessages.single['messageId'], isNotNull);
      expect(transport.sentMessages.single['payload']['supportedVersions'], ['0.1-draft']);
      expect(transport.sentMessages.single['payload']['implementationId'], 'riftd-dart/0.1.0');
      expect(transport.sentMessages.single['payload']['capabilities'], isA<List>());
      expect(transport.sentMessages.single['payload']['bindingType'], 'app-nonce');
      expect(
        base64.decode(transport.sentMessages.single['payload']['sessionNonce'] as String),
        hasLength(32),
      );
      
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
      final ctx = SessionContext(peerDeviceId: 'rift-peer', isInitiator: false)
        ..handshakeState = HandshakeState.handshaking
        ..remoteHelloReceived = true;
      sessionManager.injectContextForTesting(ctx);

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
          'bindingType': 'app-nonce',
          'sessionNonce': base64.encode(Uint8List(32)),
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

    test('sendMessage succeeds once session is established, trusted, and capability negotiated', () async {
      final ctx = SessionContext(peerDeviceId: 'rift-peer', isInitiator: true)
        ..handshakeState = HandshakeState.established
        ..trustState = TrustState.trusted
        ..capabilityNegotiated = true
        ..negotiatedCapabilities = [
          Capability(name: 'presence.basic', version: 1),
          Capability(name: 'clipboard.offer_fetch', version: 1),
        ];
      sessionManager.injectContextForTesting(ctx);

      await sessionManager.sendMessage('rift-peer', {
        'rift': '0.1-draft',
        'type': 'presence.update',
        'payload': {'status': 'online'},
      });

      expect(transport.sentMessages, hasLength(1));
      expect(transport.sentMessages.single['type'], 'presence.update');
      expect(transport.sentMessages.single['payload']['status'], 'online');
    });

    test('waitForSessionEstablished completes on disconnect and then reports session not established', () async {
      final ctx = SessionContext(peerDeviceId: 'rift-peer', isInitiator: true);
      sessionManager.injectContextForTesting(ctx);

      final future = sessionManager.waitForSessionEstablished(
        'rift-peer',
        timeout: const Duration(seconds: 1),
      );

      transport.simulateNetworkDrop('rift-peer');

      await expectLater(
        future,
        throwsA(
          isA<SessionException>().having(
            (e) => e.message,
            'message',
            contains('Session not established with rift-peer'),
          ),
        ),
      );
      expect(sessionManager.getContext('rift-peer'), isNull);
    });

    test('disconnectPeer clears context and notifies transport', () async {
      final ctx = SessionContext(peerDeviceId: 'rift-peer', isInitiator: false)
        ..handshakeState = HandshakeState.established
        ..capabilityNegotiated = true;
      sessionManager.injectContextForTesting(ctx);

      sessionManager.disconnectPeer('rift-peer');

      expect(sessionManager.getContext('rift-peer'), isNull);
      expect(transport.disconnectedPeers, contains('rift-peer'));
    });

    test('session.hello rejects missing sessionNonce', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '99999999-9999-4999-8999-999999999999',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'bindingType': 'app-nonce',
          'identityProof': '0' * 128,
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'ProtocolError');
    });

    test('session.hello rejects malformed base64 sessionNonce', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'identityProof': '0' * 128,
          'bindingType': 'app-nonce',
          'sessionNonce': 'not-base-64!@#',
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'MalformedMessage');
    });

    test('session.hello rejects invalid length sessionNonce', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'identityProof': '0' * 128,
          'bindingType': 'app-nonce',
          'sessionNonce': base64.encode(Uint8List(16)), // Only 16 bytes
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'ProtocolError');
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
          'bindingType': 'app-nonce',
          'identityProof': '0' * 128,
          'sessionNonce': base64.encode(Uint8List(32)),
          // identityVerified is intentionally omitted
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'ProtocolError');
    });

    test('session.hello rejects missing bindingType', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
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
      expect(transport.sentMessages.single['payload']['failureReason'], 'AuthenticationFailed');
    });

    test('session.hello rejects invalid sessionNonce length for app-nonce', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'identityProof': '0' * 128,
          'bindingType': 'app-nonce',
          'sessionNonce': base64.encode(Uint8List(31)),
        }
      });

      await Future.delayed(Duration.zero);

      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'ProtocolError');
    });

    test('session.accept rejects missing bindingType', () async {
      transport.registerPeerCert('rift-peer', testCertDer);
      await sessionManager.sendSessionHello('rift-peer');
      transport.sentMessages.clear();
      transport.isDisconnected = false;

      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': 'abababab-abab-4bab-8bab-abababababab',
        'type': 'session.accept',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'selectedVersion': '0.1-draft',
          'deviceId': 'rift-peer',
          'identityVerified': true,
          'capabilities': const [
            {'name': 'clipboard.offer_fetch', 'version': 1},
            {'name': 'presence.basic', 'version': 1},
            {'name': 'operation.lifecycle', 'version': 1},
            {'name': 'security.event_log', 'version': 1},
          ],
          'identityProof': '0' * 128,
          'sessionNonce': base64.encode(Uint8List(32)),
        }
      });
      await Future.delayed(Duration.zero);

      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'AuthenticationFailed');
    });

    test('rejects missing messageId', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'bindingType': 'app-nonce',
          'sessionNonce': base64.encode(Uint8List(32)),
          'identityProof': '0' * 128,
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'MalformedMessage');
    });

    test('rejects destinationDeviceId mismatch', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '12121212-1212-4121-8121-121212121212',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-someone-else',
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'bindingType': 'app-nonce',
          'sessionNonce': base64.encode(Uint8List(32)),
          'identityProof': '0' * 128,
        }
      });
      await Future.delayed(Duration.zero);
      expect(transport.isDisconnected, isTrue);
      expect(transport.sentMessages.single['payload']['failureReason'], 'Unauthorized');
    });

    test('rejects unknown requiredExtensions', () async {
      transport.simulateIncomingMessage('rift-peer', testCertDer, pubKeyBytes, {
        'rift': '0.1-draft',
        'messageId': '13131313-1313-4131-8131-131313131313',
        'type': 'session.hello',
        'sourceDeviceId': 'rift-peer',
        'destinationDeviceId': 'rift-local',
        'requiredExtensions': ['future.ext'],
        'payload': {
          'supportedVersions': ['0.1-draft'],
          'deviceId': 'rift-peer',
          'implementationId': 'riftd-peer/0.1.0',
          'capabilities': const [],
          'bindingType': 'app-nonce',
          'sessionNonce': base64.encode(Uint8List(32)),
          'identityProof': '0' * 128,
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
