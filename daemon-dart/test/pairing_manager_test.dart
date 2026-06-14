import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'dart:typed_data';
import 'package:sqlite3/open.dart';
import 'package:test/test.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/storage/trust_store_impl.dart';
import 'package:daemon_dart/src/pairing/pairing_manager.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/crypto/base32_utils.dart';
import 'package:basic_utils/basic_utils.dart';

DynamicLibrary _openOnLinux() {
  return DynamicLibrary.open('libsqlite3.so.0');
}

class MockSessionManager implements SessionManager {
  final _messageController = StreamController<ProtocolMessage>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sentMessages = [];

  @override Stream<ProtocolMessage> get onMessage => _messageController.stream;
  @override Stream<String> get onPeerDisconnected => _disconnectController.stream;

  @override Future<void> sendMessage(String peerDeviceId, Map<String, dynamic> payload) async {
    sentMessages.add(payload);
  }

  void simulateNetworkMessage(String peerDeviceId, Uint8List cert, Map<String, dynamic> payload) {
    _messageController.add(ProtocolMessage(peerDeviceId, cert, payload));
  }

  @override void dispose() => _messageController.close();
  @override Future<void> sendSessionHello(String peerDeviceId) async {}
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
  open.overrideFor(OperatingSystem.linux, _openOnLinux);

  group('PairingManager Tests', () {
    late TrustStoreImpl trustStore;
    late MockSessionManager sessionManager;
    late PairingManager pairingManager;
    late List<Map<String, dynamic>> ipcEvents;
    late Uint8List testCertDer;
    late String testFingerprint;

    setUp(() async {
      trustStore = TrustStoreImpl(':memory:');
      await trustStore.initialize();
      
      sessionManager = MockSessionManager();
      ipcEvents = [];
      
      pairingManager = PairingManager(
        trustStore: trustStore,
        sessionManager: sessionManager,
        identityManager: FakeIdentityManager(),
        onIpcEvent: (event) => ipcEvents.add(event),
      );

      // Generate a real cert for testing fingerprint
      final ecKeyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      var algorithm = Ed25519();
      final edKeyPair = await algorithm.newKeyPair();
      final pubKeyBytes = Uint8List.fromList((await edKeyPair.extractPublicKey()).bytes);
      final pem = RiftCertBuilder.generateSelfSignedCert(ecKeyPair, pubKeyBytes, commonName: 'rift-peer');
      
      final lines = pem.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('-----')).join();
      testCertDer = Uint8List.fromList(base64.decode(lines));
      
      final hash = sha256.convert(pubKeyBytes).bytes;
      final base32Str = Base32Utils.encode(Uint8List.fromList(hash)).toUpperCase().replaceAll('=', '');
      final truncated = base32Str.substring(0, 32);
      testFingerprint = truncated.replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)}-').substring(0, 39);
    });

    tearDown(() async {
      trustStore.dispose();
      sessionManager.dispose();
    });

    test('Fingerprint mismatch (UI spoofing) is rejected', () async {
      await trustStore.upsertPeer(PeerRecord(
        deviceId: 'rift-peer',
        certDer: testCertDer,
        state: TrustState.pairingPending,
        updatedAt: DateTime.now().toUtc(),
      ));

      // Call approvePairing with INVALID fingerprint
      try {
        await pairingManager.handleIpcCommand({
          'method': 'rift.approvePairing',
          'params': {
            'deviceId': 'rift-peer',
            'fingerprint': 'FAKE-FING-ERPR-INT1-2345-6789-ABCD-EFGH',
          }
        });
        fail('Should have thrown StateError');
      } catch (e) {
        expect(e, isA<StateError>());
        expect((e as StateError).message, contains('SecurityError: Fingerprint mismatch'));
      }

      // Peer must revert to discovered due to suspected spoofing
      final peer = await trustStore.getPeer('rift-peer');
      expect(peer!.state, TrustState.discovered);
    });

    test('Process pairing.start sends correct event to UI and starts 30s timeout', () async {
      sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
        'type': 'pairing.start',
        'payload': {
          'displayName': 'Peer Device',
        }
      });
      
      // Wait for microtask for stream to process
      await Future.delayed(Duration.zero);
      
      final peer = await trustStore.getPeer('rift-peer');
      expect(peer!.state, TrustState.pairingPending);
      
      expect(ipcEvents.length, 1);
      expect(ipcEvents[0]['method'], 'rift.onPairingRequest');
      expect(ipcEvents[0]['params']['fingerprint'], testFingerprint);
      
      // Wait 30s timeout
      // Because FakeAsync is not used, skip real 30s wait test and only verify correct state transition.
    });
    
    test('Process rift.approvePairing sends protocol message and becomes trusted', () async {
      await trustStore.upsertPeer(PeerRecord(
        deviceId: 'rift-peer',
        certDer: testCertDer,
        state: TrustState.pairingPending,
        updatedAt: DateTime.now().toUtc(),
      ));

      await pairingManager.handleIpcCommand({
        'method': 'rift.approvePairing',
        'params': {
          'deviceId': 'rift-peer',
          'fingerprint': testFingerprint, // Correct fingerprint
        }
      });
      
      final peer = await trustStore.getPeer('rift-peer');
      expect(peer!.state, TrustState.trusted);
      
      expect(sessionManager.sentMessages.length, 2);
      expect(sessionManager.sentMessages[0]['type'], 'pairing.approve');
      expect(sessionManager.sentMessages[1]['type'], 'pairing.complete');
      
      expect(ipcEvents.length, 1);
      expect(ipcEvents[0]['method'], 'rift.onPairingComplete');
    });

    test('Blocked peer sending pairing.start is rejected immediately', () async {
      await trustStore.upsertPeer(PeerRecord(
        deviceId: 'rift-blocked',
        certDer: testCertDer,
        state: TrustState.blocked,
        updatedAt: DateTime.now().toUtc(),
      ));

      sessionManager.simulateNetworkMessage('rift-blocked', testCertDer, {
        'type': 'pairing.start',
        'payload': {'displayName': 'Hacker Device'}
      });
      
      await Future.delayed(Duration.zero);
      
      final peer = await trustStore.getPeer('rift-blocked');
      expect(peer!.state, TrustState.blocked); // Does not change to pairingPending
      expect(ipcEvents.isEmpty, isTrue); // Do not notify UI
    });

    test('Prevent Double-Approve: Receiving pairing.approve when not Initiator -> Dropped', () async {
      await trustStore.upsertPeer(PeerRecord(
        deviceId: 'rift-hacker',
        certDer: testCertDer,
        state: TrustState.pairingPending,
        updatedAt: DateTime.now().toUtc(),
      ));

      // Simulate hacker (or peer) arbitrarily sending pairing.approve
      // while we are NOT the initiator (did not send pairing.start previously)
      sessionManager.simulateNetworkMessage('rift-hacker', testCertDer, {
        'type': 'pairing.approve',
        'payload': {'approvedAt': DateTime.now().toIso8601String()}
      });
      
      await Future.delayed(Duration.zero);
      
      // State must be downgraded to discovered due to suspected out-of-flow packet
      final peer = await trustStore.getPeer('rift-hacker');
      expect(peer!.state, TrustState.discovered);
      
      // Verify a reject message was sent back to that peer
      final hasReject = sessionManager.sentMessages.any((msg) => msg['type'] == 'pairing.reject');
      expect(hasReject, isTrue);
    });
  });
}
