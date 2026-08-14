import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  group('SessionManager connection ownership', () {
    late _ScopedFakeTransport transport;
    late _FakeTrustStore trustStore;
    late _FakeIdentityManager identityManager;
    late SessionManager manager;

    setUp(() {
      transport = _ScopedFakeTransport();
      trustStore = _FakeTrustStore();
      identityManager = _FakeIdentityManager();
      manager = SessionManager(transport, identityManager, trustStore);
    });

    tearDown(() async {
      await manager.dispose();
      await transport.dispose();
    });

    test('stale async message failure cannot disconnect replacement', () async {
      final firstConnection = Object();
      final replacementConnection = Object();
      transport.setCurrentConnection('rift-peer', firstConnection);
      final firstContext = _establishedContext(firstConnection);
      manager.injectContextForTesting(firstContext);
      transport.blockedMessageType = 'capability.selected';

      transport.emitMessage(
        'rift-peer',
        firstConnection,
        'capability.advertise',
        {
          'capabilities': [
            {'name': 'presence.basic', 'version': 1},
          ],
        },
      );
      await transport.blockedSendStarted.future;

      transport.setCurrentConnection('rift-peer', replacementConnection);
      final replacementContext = _establishedContext(replacementConnection)
        ..currentPresenceStatus = 'online';
      manager.injectContextForTesting(replacementContext);
      transport.releaseBlockedSend.complete();
      final disconnectedToken = await transport.teardownAttempted.future;

      expect(disconnectedToken, same(firstConnection));
      expect(
        transport.currentConnectionToken('rift-peer'),
        same(replacementConnection),
      );
      expect(manager.getContext('rift-peer'), same(replacementContext));
      expect(replacementContext.currentPresenceStatus, 'online');
      expect(transport.peerDisconnects, isEmpty);
    });

    test('stale disconnect event cannot remove replacement session', () async {
      final firstConnection = Object();
      final replacementConnection = Object();
      transport.setCurrentConnection('rift-peer', replacementConnection);
      final replacementContext = _establishedContext(replacementConnection)
        ..currentPresenceStatus = 'online';
      manager.injectContextForTesting(replacementContext);

      transport.emitConnectionDisconnected('rift-peer', firstConnection);
      await Future<void>.delayed(Duration.zero);

      expect(manager.getContext('rift-peer'), same(replacementContext));
      expect(replacementContext.currentPresenceStatus, 'online');
    });

    test('locally initiated session does not move onto replacement', () async {
      final firstConnection = Object();
      final replacementConnection = Object();
      transport.setCurrentConnection('rift-peer', firstConnection);
      transport.peerCertificates['rift-peer'] = Uint8List(32);
      identityManager.blockIdentityProof = true;

      final sendHello = manager.sendSessionHello('rift-peer');
      await identityManager.identityProofStarted.future;
      transport.setCurrentConnection('rift-peer', replacementConnection);
      identityManager.releaseIdentityProof.complete();

      await expectLater(sendHello, throwsA(isA<SessionException>()));
      expect(transport.sentMessages, isEmpty);
      expect(transport.peerDisconnects, isEmpty);
      expect(
        transport.currentConnectionToken('rift-peer'),
        same(replacementConnection),
      );
    });

    test(
      'one heartbeat send failure does not disconnect the session',
      () async {
        final connection = Object();
        transport.setCurrentConnection('rift-peer', connection);
        final context = _establishedContext(connection)
          ..trustState = TrustState.discovered;
        manager.injectContextForTesting(context);
        transport.presenceFailuresRemaining = 1;
        final firstAttempt = transport.onPresenceAttempt.firstWhere(
          (attempt) => attempt == 1,
        );

        manager.updateTrustState('rift-peer', TrustState.trusted);
        await firstAttempt;
        await Future<void>.delayed(Duration.zero);

        expect(transport.presenceAttempts, 1);
        expect(transport.teardownTokens, isEmpty);
        expect(manager.getContext('rift-peer'), same(context));

        final secondAttempt = transport.onPresenceAttempt.firstWhere(
          (attempt) => attempt == 2,
        );
        manager.updateTrustState('rift-peer', TrustState.discovered);
        manager.updateTrustState('rift-peer', TrustState.trusted);
        await secondAttempt;
        await Future<void>.delayed(Duration.zero);

        expect(transport.presenceAttempts, 2);
        expect(transport.teardownTokens, isEmpty);
        expect(manager.getContext('rift-peer'), same(context));
      },
    );

    test(
      'heartbeat cancels old timeout before last-seen persistence',
      () async {
        final connection = Object();
        transport.setCurrentConnection('rift-peer', connection);
        final context = _establishedContext(connection)
          ..currentPresenceStatus = 'online';
        manager.injectContextForTesting(context);
        final oldTimeout = _ManualTimer(
          () => transport.disconnect('rift-peer'),
        );
        context.offlineTimeoutTimer = oldTimeout;
        trustStore.blockLastSeenUpdate = true;

        transport.emitMessage('rift-peer', connection, 'presence.update', {
          'status': 'online',
          'capabilities': ['presence.basic'],
        });
        await trustStore.lastSeenUpdateStarted.future;

        oldTimeout.fire();
        expect(oldTimeout.wasCancelled, isTrue);
        expect(transport.peerDisconnects, isEmpty);
        expect(manager.getContext('rift-peer'), same(context));

        trustStore.releaseLastSeenUpdate.complete();
        await trustStore.lastSeenUpdateFinished.future;
        expect(context.currentPresenceStatus, 'online');
      },
    );

    test('last-seen persistence failure keeps in-memory liveness', () async {
      final connection = Object();
      transport.setCurrentConnection('rift-peer', connection);
      final context = _establishedContext(connection);
      manager.injectContextForTesting(context);
      trustStore.lastSeenUpdateError = StateError('database unavailable');

      final presenceUpdated = manager.onPresenceUpdate.first;
      transport.emitMessage('rift-peer', connection, 'presence.update', {
        'status': 'away',
        'capabilities': ['presence.basic'],
      });

      expect((await presenceUpdated).currentPresenceStatus, 'away');
      await trustStore.lastSeenUpdateFinished.future;
      expect(transport.peerDisconnects, isEmpty);
      expect(manager.getContext('rift-peer'), same(context));
    });

    test(
      'dispose cancels transport subscriptions before closing outputs',
      () async {
        expect(transport.hasMessageListener, isTrue);
        expect(transport.hasConnectionDisconnectListener, isTrue);

        await manager.dispose();

        expect(transport.hasMessageListener, isFalse);
        expect(transport.hasConnectionDisconnectListener, isFalse);
        transport.emitMessage('rift-peer', Object(), 'presence.update', const {
          'status': 'online',
          'capabilities': ['presence.basic'],
        });
        transport.emitConnectionDisconnected('rift-peer', Object());
        await Future<void>.delayed(Duration.zero);
        expect(transport.teardownTokens, isEmpty);
      },
    );
  });
}

SessionContext _establishedContext(Object connectionToken) =>
    SessionContext(
        peerDeviceId: 'rift-peer',
        isInitiator: true,
        connectionToken: connectionToken,
      )
      ..handshakeState = HandshakeState.established
      ..trustState = TrustState.trusted
      ..capabilityNegotiated = true
      ..localAdvertisedCapabilities = [
        Capability(name: 'clipboard.offer_fetch', version: 1),
        Capability(name: 'presence.basic', version: 1),
        Capability(name: 'operation.lifecycle', version: 1),
        Capability(name: 'security.event_log', version: 1),
      ]
      ..negotiatedCapabilities = [
        Capability(name: 'clipboard.offer_fetch', version: 1),
        Capability(name: 'presence.basic', version: 1),
        Capability(name: 'operation.lifecycle', version: 1),
        Capability(name: 'security.event_log', version: 1),
      ];

class _ScopedFakeTransport implements Transport, ConnectionScopedTransport {
  final _messages = StreamController<TransportMessage>.broadcast(sync: true);
  final _peerDisconnects = StreamController<String>.broadcast(sync: true);
  final _connectionDisconnects =
      StreamController<TransportDisconnect>.broadcast(sync: true);
  final _presenceAttemptController = StreamController<int>.broadcast(
    sync: true,
  );
  final Map<String, Object> _connections = {};
  final Map<String, Uint8List> peerCertificates = {};
  final List<Map<String, dynamic>> sentMessages = [];
  final List<String> peerDisconnects = [];
  final List<Object?> teardownTokens = [];
  final blockedSendStarted = Completer<void>();
  final releaseBlockedSend = Completer<void>();
  final teardownAttempted = Completer<Object?>();
  String? blockedMessageType;
  int presenceFailuresRemaining = 0;
  int presenceAttempts = 0;

  Stream<int> get onPresenceAttempt => _presenceAttemptController.stream;

  bool get hasMessageListener => _messages.hasListener;
  bool get hasConnectionDisconnectListener =>
      _connectionDisconnects.hasListener;

  void setCurrentConnection(String peerDeviceId, Object connectionToken) {
    _connections[peerDeviceId] = connectionToken;
  }

  void emitMessage(
    String peerDeviceId,
    Object connectionToken,
    String type,
    Map<String, dynamic> payload,
  ) {
    _messages.add(
      TransportMessage(
        peerDeviceId: peerDeviceId,
        payload: Uint8List.fromList(
          utf8.encode(
            json.encode({
              'rift': '0.1-draft',
              'messageId': const Uuid().v4(),
              'type': type,
              'sourceDeviceId': peerDeviceId,
              'destinationDeviceId': 'rift-local',
              'payload': payload,
            }),
          ),
        ),
        peerEd25519Key: Uint8List(32),
        peerCertDer: Uint8List(32),
        connectionToken: connectionToken,
      ),
    );
  }

  void emitConnectionDisconnected(String peerDeviceId, Object connectionToken) {
    _connectionDisconnects.add(
      TransportDisconnect(
        peerDeviceId: peerDeviceId,
        connectionToken: connectionToken,
      ),
    );
  }

  @override
  Object? currentConnectionToken(String peerDeviceId) =>
      _connections[peerDeviceId];

  @override
  bool isCurrentConnection(String peerDeviceId, Object? connectionToken) =>
      identical(_connections[peerDeviceId], connectionToken);

  @override
  void disconnectConnection(String peerDeviceId, Object? connectionToken) {
    teardownTokens.add(connectionToken);
    if (!teardownAttempted.isCompleted) {
      teardownAttempted.complete(connectionToken);
    }
    if (!isCurrentConnection(peerDeviceId, connectionToken)) {
      return;
    }
    _connections.remove(peerDeviceId);
    emitConnectionDisconnected(peerDeviceId, connectionToken!);
    peerDisconnects.add(peerDeviceId);
    _peerDisconnects.add(peerDeviceId);
  }

  @override
  void disconnect(String peerDeviceId) {
    final connectionToken = _connections.remove(peerDeviceId);
    teardownTokens.add(connectionToken);
    if (!teardownAttempted.isCompleted) {
      teardownAttempted.complete(connectionToken);
    }
    peerDisconnects.add(peerDeviceId);
    if (connectionToken != null) {
      emitConnectionDisconnected(peerDeviceId, connectionToken);
    }
    _peerDisconnects.add(peerDeviceId);
  }

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    final decoded = json.decode(utf8.decode(message)) as Map<String, dynamic>;
    sentMessages.add(decoded);
    final type = decoded['type'];
    if (type == 'presence.update') {
      presenceAttempts += 1;
      _presenceAttemptController.add(presenceAttempts);
      if (presenceFailuresRemaining > 0) {
        presenceFailuresRemaining -= 1;
        throw const SocketException('Injected heartbeat failure');
      }
    }
    if (type == blockedMessageType) {
      if (!blockedSendStarted.isCompleted) {
        blockedSendStarted.complete();
      }
      await releaseBlockedSend.future;
      throw StateError('Injected stale send failure');
    }
  }

  @override
  Stream<TransportMessage> get onMessageReceived => _messages.stream;

  @override
  Stream<String> get onPeerDisconnected => _peerDisconnects.stream;

  @override
  Stream<TransportDisconnect> get onConnectionDisconnected =>
      _connectionDisconnects.stream;

  @override
  Uint8List? getPeerCert(String peerDeviceId) => peerCertificates[peerDeviceId];

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) => null;

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
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {}

  Future<void> dispose() async {
    if (!releaseBlockedSend.isCompleted) {
      releaseBlockedSend.complete();
    }
    await _messages.close();
    await _peerDisconnects.close();
    await _connectionDisconnects.close();
    await _presenceAttemptController.close();
  }
}

class _FakeIdentityManager implements IdentityManager {
  bool blockIdentityProof = false;
  final identityProofStarted = Completer<void>();
  final releaseIdentityProof = Completer<void>();

  @override
  String get deviceId => 'rift-local';

  @override
  String get displayName => 'Local device';

  @override
  Uint8List get tlsCertificateDer => Uint8List(32);

  @override
  String get tlsCertificatePem => '';

  @override
  String get tlsPrivateKeyPem => '';

  @override
  Uint8List getDeviceFingerprint() => Uint8List(32);

  @override
  Uint8List getEd25519PublicKey() => Uint8List(32);

  @override
  Future<String> generateIdentityProof(
    Uint8List channelBinding,
    Uint8List localCertDer,
  ) async {
    if (blockIdentityProof) {
      identityProofStarted.complete();
      await releaseIdentityProof.future;
    }
    return '0' * 128;
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeTrustStore implements TrustStore {
  bool blockLastSeenUpdate = false;
  Object? lastSeenUpdateError;
  final lastSeenUpdateStarted = Completer<void>();
  final releaseLastSeenUpdate = Completer<void>();
  final lastSeenUpdateFinished = Completer<void>();

  @override
  Future<PeerRecord?> getPeer(String deviceId) async => PeerRecord(
    deviceId: deviceId,
    certDer: Uint8List(32),
    state: TrustState.trusted,
    updatedAt: DateTime.now().toUtc(),
  );

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {
    if (!lastSeenUpdateStarted.isCompleted) {
      lastSeenUpdateStarted.complete();
    }
    try {
      if (blockLastSeenUpdate) {
        await releaseLastSeenUpdate.future;
      }
      final error = lastSeenUpdateError;
      if (error != null) {
        throw error;
      }
    } finally {
      if (!lastSeenUpdateFinished.isCompleted) {
        lastSeenUpdateFinished.complete();
      }
    }
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> upsertPeer(PeerRecord record) async {}

  @override
  Future<List<PeerRecord>> getAllPeers() async => [];

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
  Future<void> appendSecurityEvent(SecurityEventRecord record) async {}

  @override
  Future<List<SecurityEventRecord>> querySecurityEvents(
    SecurityEventQuery query,
  ) async => [];

  @override
  Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;
}

class _ManualTimer implements Timer {
  final void Function() _callback;
  bool _isActive = true;
  bool wasCancelled = false;

  _ManualTimer(this._callback);

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }

  @override
  void cancel() {
    wasCancelled = true;
    _isActive = false;
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;
}
