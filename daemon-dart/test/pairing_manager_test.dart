import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:daemon_dart/src/core/rift_exceptions.dart';
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

class MockSessionManager implements SessionManager {
  final Map<String, SessionContext> contexts = {};

  @override
  Future<bool> Function(String)? get peerAllowanceResolver => null;

  @override
  SessionContext? getContext(String peerDeviceId) => contexts[peerDeviceId];
  @override
  void injectContextForTesting(SessionContext ctx) {}
  @override
  void requireCapability(String peerDeviceId, String capabilityName) {}
  @override
  Future<void> waitForSessionEstablished(
    String peerDeviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {}
  @override
  Stream<SessionContext> get onPresenceUpdate => const Stream.empty();
  @override
  Stream<SessionContext> get onTrustedSessionReady => const Stream.empty();

  final _messageController = StreamController<ProtocolMessage>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sentMessages = [];
  final List<String> disconnectedPeers = [];
  bool shouldFailSend = false;

  @override
  Stream<ProtocolMessage> get onMessage => _messageController.stream;
  @override
  Stream<String> get onPeerDisconnected => _disconnectController.stream;

  @override
  Future<void> sendMessage(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    if (shouldFailSend) {
      throw SessionException('Simulated send failure');
    }
    sentMessages.add(payload);
  }

  void simulateNetworkMessage(
    String peerDeviceId,
    Uint8List? cert,
    Map<String, dynamic> payload,
  ) {
    _messageController.add(ProtocolMessage(peerDeviceId, cert, payload));
  }

  void simulateDisconnect(String peerDeviceId) {
    _disconnectController.add(peerDeviceId);
  }

  @override
  void disconnectPeer(String peerDeviceId) {
    disconnectedPeers.add(peerDeviceId);
  }

  @override
  Future<void> dispose() async {
    await _messageController.close();
    await _disconnectController.close();
  }

  @override
  Future<void> sendSessionHello(String peerDeviceId) async {}

  @override
  void updateTrustState(String peerDeviceId, TrustState newState) {}
}

class FakeIdentityManager implements IdentityManager {
  @override
  String get deviceId => 'rift-local';
  @override
  String get displayName => 'Android Phone 01';
  @override
  Uint8List getDeviceFingerprint() => Uint8List(32);
  @override
  Uint8List getEd25519PublicKey() => Uint8List(32);
  @override
  String get tlsCertificatePem => '';
  @override
  Uint8List get tlsCertificateDer => Uint8List(0);
  @override
  String get tlsPrivateKeyPem => '';
  @override
  Future<void> dispose() async {}
  @override
  Future<void> initialize() async {}
  @override
  Future<String> generateIdentityProof(Uint8List c, Uint8List l) async =>
      'proof';
}

void main() {
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
      final pubKeyBytes = Uint8List.fromList(
        (await edKeyPair.extractPublicKey()).bytes,
      );
      final pem = RiftCertBuilder.generateSelfSignedCert(
        ecKeyPair,
        pubKeyBytes,
        commonName: 'rift-peer',
      );

      final lines = pem
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('-----'))
          .join();
      testCertDer = Uint8List.fromList(base64.decode(lines));

      final hash = sha256.convert(pubKeyBytes).bytes;
      final base32Str = Base32Utils.encode(
        Uint8List.fromList(hash),
      ).toUpperCase().replaceAll('=', '');
      final truncated = base32Str.substring(0, 32);
      testFingerprint = truncated
          .replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)}-')
          .substring(0, 39);
    });

    tearDown(() async {
      await pairingManager.dispose();
      trustStore.dispose();
      await sessionManager.dispose();
    });

    test('Fingerprint mismatch (UI spoofing) is rejected', () async {
      await trustStore.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer',
          certDer: testCertDer,
          state: TrustState.pairingPending,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      // Call approvePairing with INVALID fingerprint
      try {
        await pairingManager.handleIpcCommand({
          'method': 'rift.approvePairing',
          'params': {
            'deviceId': 'rift-peer',
            'fingerprint': 'FAKE-FING-ERPR-INT1-2345-6789-ABCD-EFGH',
          },
        });
        fail('Should have thrown RiftAuthenticationFailedException');
      } catch (e) {
        expect(e, isA<RiftAuthenticationFailedException>());
        expect(
          (e as RiftAuthenticationFailedException).message,
          contains('SecurityError: Fingerprint mismatch'),
        );
      }

      // Peer must revert to discovered due to suspected spoofing
      final peer = await trustStore.getPeer('rift-peer');
      expect(peer!.state, TrustState.discovered);
    });

    test(
      'Process pairing.start sends correct event to UI and uses peer expiry',
      () async {
        sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
          'type': 'pairing.start',
          'payload': {'expiresInMs': 120000, 'displayName': 'Peer Device'},
        });

        // Wait for microtask for stream to process
        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer!.state, TrustState.pairingPending);

        expect(ipcEvents.length, 1);
        expect(ipcEvents[0]['method'], 'rift.onPairingRequest');
        expect(ipcEvents[0]['params']['fingerprint'], testFingerprint);

        expect(ipcEvents[0]['params']['expiresInMs'], 120000);
        // Because FakeAsync is not used, skip waiting for the actual timer and
        // verify the surfaced expiry instead.
      },
    );

    test(
      'Process pairing.start still notifies UI when peer is already pairingPending',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.pairingPending,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
          'type': 'pairing.start',
          'payload': {'expiresInMs': 120000, 'displayName': 'Peer Device'},
        });

        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer!.state, TrustState.pairingPending);
        expect(ipcEvents.length, 1);
        expect(ipcEvents[0]['method'], 'rift.onPairingRequest');
        expect(ipcEvents[0]['params']['displayName'], 'Peer Device');
      },
    );

    test(
      'Process rift.approvePairing sends protocol message and becomes trusted',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.pairingPending,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        await pairingManager.handleIpcCommand({
          'method': 'rift.approvePairing',
          'params': {
            'deviceId': 'rift-peer',
            'fingerprint': testFingerprint, // Correct fingerprint
          },
        });

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer!.state, TrustState.trusted);

        expect(sessionManager.sentMessages.length, 2);
        expect(sessionManager.sentMessages[0]['type'], 'pairing.approve');
        expect(sessionManager.sentMessages[0]['messageId'], isNotNull);
        expect(sessionManager.sentMessages[1]['type'], 'pairing.complete');
        expect(sessionManager.sentMessages[1]['messageId'], isNotNull);

        expect(ipcEvents.length, 1);
        expect(ipcEvents[0]['method'], 'rift.onPairingComplete');
      },
    );

    test('resetRevokedPeer removes legacy revoked peer record', () async {
      await trustStore.upsertPeer(
        PeerRecord(
          deviceId: 'rift-revoked',
          certDer: testCertDer,
          state: TrustState.revoked,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      await pairingManager.handleIpcCommand({
        'method': 'rift.resetRevokedPeer',
        'params': {'deviceId': 'rift-revoked'},
      });

      final peer = await trustStore.getPeer('rift-revoked');
      expect(peer, isNull);
      expect(ipcEvents.single['method'], 'rift.onTrustChanged');
      expect(ipcEvents.single['params']['previousState'], 'revoked');
      expect(ipcEvents.single['params']['newState'], 'removed');
    });

    test(
      'unpair sends advisory trust.remove before deleting local peer',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.trusted,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        await pairingManager.handleIpcCommand({
          'method': 'rift.unpair',
          'params': {
            'deviceId': 'rift-peer',
            'reason': 'User removed trusted device',
          },
        });

        expect(await trustStore.getPeer('rift-peer'), isNull);
        expect(sessionManager.disconnectedPeers, ['rift-peer']);
        expect(sessionManager.sentMessages, hasLength(1));
        expect(sessionManager.sentMessages.single['type'], 'trust.remove');
        expect(
          sessionManager.sentMessages.single['payload']['removedDeviceId'],
          'rift-peer',
        );
        expect(ipcEvents.single['method'], 'rift.onTrustChanged');
        expect(ipcEvents.single['params']['newState'], 'removed');
      },
    );

    test('incoming trust.remove clears stale trusted peer locally', () async {
      await trustStore.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer',
          certDer: testCertDer,
          state: TrustState.trusted,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
        'type': 'trust.remove',
        'payload': {
          'removedDeviceId': 'rift-local',
          'reason': 'Peer removed trusted device',
          'removedAt': DateTime.now().toUtc().toIso8601String(),
        },
      });

      await Future.delayed(Duration.zero);

      expect(await trustStore.getPeer('rift-peer'), isNull);
      expect(sessionManager.disconnectedPeers, ['rift-peer']);
      expect(ipcEvents.single['method'], 'rift.onTrustChanged');
      expect(ipcEvents.single['params']['previousState'], 'trusted');
      expect(ipcEvents.single['params']['newState'], 'removed');
    });

    test(
      'approvePairing keeps pairing pending if network send fails',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.pairingPending,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        sessionManager.shouldFailSend = true;

        expect(
          () => pairingManager.handleIpcCommand({
            'method': 'rift.approvePairing',
            'params': {'deviceId': 'rift-peer', 'fingerprint': testFingerprint},
          }),
          throwsA(isA<SessionException>()),
        );

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer!.state, TrustState.pairingPending);
        expect(ipcEvents, isEmpty);
      },
    );

    test(
      'Blocked peer sending pairing.start is rejected immediately',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-blocked',
            certDer: testCertDer,
            state: TrustState.blocked,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        sessionManager.simulateNetworkMessage('rift-blocked', testCertDer, {
          'type': 'pairing.start',
          'payload': {'displayName': 'Hacker Device', 'expiresInMs': 120000},
        });

        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-blocked');
        expect(
          peer!.state,
          TrustState.blocked,
        ); // Does not change to pairingPending
        expect(ipcEvents.isEmpty, isTrue); // Do not notify UI
      },
    );

    test(
      'Prevent Double-Approve: Receiving pairing.approve when not Initiator -> Dropped',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-hacker',
            certDer: testCertDer,
            state: TrustState.pairingPending,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        // Simulate hacker (or peer) arbitrarily sending pairing.approve
        // while we are NOT the initiator (did not send pairing.start previously)
        sessionManager.simulateNetworkMessage('rift-hacker', testCertDer, {
          'type': 'pairing.approve',
          'payload': {'approvedAt': DateTime.now().toIso8601String()},
        });

        await Future.delayed(Duration.zero);

        // State must be downgraded to discovered due to suspected out-of-flow packet
        final peer = await trustStore.getPeer('rift-hacker');
        expect(peer!.state, TrustState.discovered);

        // Verify a reject message was sent back to that peer
        final hasReject = sessionManager.sentMessages.any(
          (msg) => msg['type'] == 'pairing.reject',
        );
        expect(hasReject, isTrue);
        final rejectMessage = sessionManager.sentMessages.firstWhere(
          (msg) => msg['type'] == 'pairing.reject',
        );
        expect(rejectMessage['payload']['failureReason'], 'PolicyDenied');
      },
    );

    test(
      'Outbound pairing stays pending after remote approval until pairing.complete arrives',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.discovered,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        await pairingManager.handleIpcCommand({
          'method': 'rift.startPairing',
          'params': {'deviceId': 'rift-peer'},
        });

        sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
          'type': 'pairing.approve',
          'payload': {'approvedAt': DateTime.now().toIso8601String()},
        });

        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer!.state, TrustState.pairingPending);
        expect(
          ipcEvents.any((event) => event['method'] == 'rift.onPairingApproved'),
          isTrue,
        );
        expect(
          ipcEvents.any((event) => event['method'] == 'rift.onPairingComplete'),
          isFalse,
        );
      },
    );

    test(
      'Outbound pairing completes only after remote pairing.complete arrives',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.discovered,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        await pairingManager.handleIpcCommand({
          'method': 'rift.startPairing',
          'params': {'deviceId': 'rift-peer'},
        });

        sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
          'type': 'pairing.approve',
          'payload': {'approvedAt': DateTime.now().toIso8601String()},
        });
        await Future.delayed(Duration.zero);

        sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
          'type': 'pairing.complete',
          'payload': {
            'trustedDeviceId': 'rift-peer',
            'persistedAt': DateTime.now().toUtc().toIso8601String(),
          },
        });

        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer!.state, TrustState.trusted);
        expect(
          ipcEvents.any((event) => event['method'] == 'rift.onPairingComplete'),
          isTrue,
        );
      },
    );

    test('startPairing rolls state back if network send fails', () async {
      await trustStore.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer',
          certDer: testCertDer,
          state: TrustState.discovered,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      sessionManager.shouldFailSend = true;

      expect(
        () => pairingManager.handleIpcCommand({
          'method': 'rift.startPairing',
          'params': {'deviceId': 'rift-peer'},
        }),
        throwsA(isA<SessionException>()),
      );

      final peer = await trustStore.getPeer('rift-peer');
      expect(peer!.state, TrustState.discovered);
    });

    test(
      'Legacy revoked peer sending pairing.start is treated as forgotten',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-revoked',
            certDer: testCertDer,
            state: TrustState.revoked,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        sessionManager.simulateNetworkMessage('rift-revoked', testCertDer, {
          'type': 'pairing.start',
          'payload': {'displayName': 'Revoked Device', 'expiresInMs': 120000},
        });

        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-revoked');
        expect(peer, isNotNull);
        expect(peer!.state, TrustState.pairingPending);
        expect(
          ipcEvents.where(
            (event) => event['method'] == 'rift.onPairingRequest',
          ),
          isNotEmpty,
        );
      },
    );

    test('Trusted peer sending pairing.start is ignored', () async {
      await trustStore.upsertPeer(
        PeerRecord(
          deviceId: 'rift-trusted',
          certDer: testCertDer,
          state: TrustState.trusted,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      sessionManager.simulateNetworkMessage('rift-trusted', testCertDer, {
        'type': 'pairing.start',
        'payload': {'displayName': 'Trusted Device', 'expiresInMs': 120000},
      });

      await Future.delayed(Duration.zero);

      final peer = await trustStore.getPeer('rift-trusted');
      expect(peer!.state, TrustState.trusted);
      expect(
        ipcEvents.where((event) => event['method'] == 'rift.onPairingRequest'),
        isEmpty,
      );
    });

    test(
      'Trusted peer keeps pinned certDer when a new cert is observed',
      () async {
        final originalCert = Uint8List.fromList(testCertDer);
        final rotatedCert = Uint8List.fromList([...testCertDer, 0x01]);

        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-trusted',
            certDer: originalCert,
            state: TrustState.trusted,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        sessionManager.simulateNetworkMessage('rift-trusted', rotatedCert, {
          'type': 'pairing.start',
          'payload': {'displayName': 'Trusted Device', 'expiresInMs': 120000},
        });

        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-trusted');
        expect(peer, isNotNull);
        expect(peer!.certDer, orderedEquals(originalCert));
        expect(peer.state, TrustState.trusted);
      },
    );

    test(
      'pairing.complete with mismatched trustedDeviceId is rejected',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.pairingPending,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
          'type': 'pairing.complete',
          'payload': {
            'trustedDeviceId': 'rift-other',
            'persistedAt': DateTime.now().toUtc().toIso8601String(),
          },
        });

        await Future.delayed(Duration.zero);

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer!.state, TrustState.discovered);
        final hasReject = sessionManager.sentMessages.any(
          (msg) => msg['type'] == 'pairing.reject',
        );
        expect(hasReject, isTrue);
      },
    );

    test('Unpair revokes trust and disconnects active peer session', () async {
      await trustStore.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer',
          certDer: testCertDer,
          state: TrustState.trusted,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      await pairingManager.handleIpcCommand({
        'method': 'rift.unpair',
        'params': {'deviceId': 'rift-peer', 'reason': 'User requested unpair'},
      });

      final peer = await trustStore.getPeer('rift-peer');
      expect(peer, isNull);
      expect(sessionManager.disconnectedPeers, contains('rift-peer'));
      expect(ipcEvents.single['params']['reason'], 'User requested unpair');
      expect(ipcEvents.single['params']['newState'], 'removed');
    });

    test('Unblock peer returns blocked device to discovered', () async {
      await trustStore.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer',
          certDer: testCertDer,
          state: TrustState.blocked,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      await pairingManager.handleIpcCommand({
        'method': 'rift.unblockPeer',
        'params': {'deviceId': 'rift-peer'},
      });

      final peer = await trustStore.getPeer('rift-peer');
      expect(peer!.state, TrustState.discovered);
      expect(ipcEvents.single['method'], 'rift.onTrustChanged');
      expect(ipcEvents.single['params']['newState'], 'discovered');
    });

    test(
      'IPC command validation rejects missing or wrong-type params',
      () async {
        await expectLater(
          pairingManager.handleIpcCommand({
            'method': 'rift.startPairing',
            'params': const {},
          }),
          throwsA(isA<ArgumentError>()),
        );

        await expectLater(
          pairingManager.handleIpcCommand({
            'method': 'rift.unpair',
            'params': {'deviceId': 'rift-peer', 'reason': 123},
          }),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('Malformed pairing.start disconnects peer', () async {
      sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
        'type': 'pairing.start',
        'payload': {'displayName': 'Peer Device'},
      });

      await Future.delayed(Duration.zero);

      expect(sessionManager.disconnectedPeers, contains('rift-peer'));
      final peer = await trustStore.getPeer('rift-peer');
      expect(peer, isNotNull);
      expect(peer!.state, TrustState.discovered);
      expect(ipcEvents, isEmpty);
    });

    test(
      'pairing.start without peer cert disconnects instead of crashing',
      () async {
        sessionManager.simulateNetworkMessage('rift-missing-cert', null, {
          'type': 'pairing.start',
          'payload': {'displayName': 'Peer Device', 'expiresInMs': 120000},
        });

        await Future.delayed(Duration.zero);

        expect(sessionManager.disconnectedPeers, contains('rift-missing-cert'));
        expect(ipcEvents, isEmpty);
        final peer = await trustStore.getPeer('rift-missing-cert');
        expect(peer, isNull);
      },
    );

    test('dispose cancels pending timers and unsubscribes listeners', () async {
      sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
        'type': 'pairing.start',
        'payload': {'displayName': 'Peer Device', 'expiresInMs': 120000},
      });
      await Future.delayed(Duration.zero);

      await pairingManager.dispose();
      trustStore.dispose();

      sessionManager.simulateNetworkMessage('rift-peer', testCertDer, {
        'type': 'pairing.reject',
        'payload': {'failureReason': 'PolicyDenied'},
      });
      await Future.delayed(Duration.zero);

      expect(sessionManager.disconnectedPeers, isNot(contains('rift-peer')));
    });

    test(
      'transient disconnect during pairing does not revert when replacement session appears quickly',
      () async {
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-peer',
            certDer: testCertDer,
            state: TrustState.pairingPending,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        sessionManager.simulateDisconnect('rift-peer');

        Future<void>.delayed(const Duration(milliseconds: 200), () {
          final ctx =
              SessionContext(peerDeviceId: 'rift-peer', isInitiator: true)
                ..handshakeState = HandshakeState.established
                ..capabilityNegotiated = true;
          sessionManager.contexts['rift-peer'] = ctx;
        });

        await Future<void>.delayed(const Duration(milliseconds: 1700));

        final peer = await trustStore.getPeer('rift-peer');
        expect(peer, isNotNull);
        expect(peer!.state, TrustState.pairingPending);
      },
    );
  });
}
