import 'dart:typed_data';

import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:test/test.dart';

class _FakeTrustStore implements TrustStore {
  final Map<String, PeerRecord> _peers = {};
  final List<String> deletedPeers = [];

  @override
  Future<void> appendSecurityEvent(SecurityEventRecord record) async {}

  @override
  Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;

  @override
  Future<void> deletePeer(String deviceId) async {
    deletedPeers.add(deviceId);
    _peers.remove(deviceId);
  }

  @override
  Future<List<PeerRecord>> getAllPeers() async => _peers.values.toList();

  @override
  Future<PeerRecord?> getPeer(String deviceId) async => _peers[deviceId];

  @override
  Future<List<PeerRecord>> getPeersByState(TrustState state) async =>
      _peers.values.where((peer) => peer.state == state).toList();

  @override
  Future<void> initialize() async {}

  @override
  Future<List<SecurityEventRecord>> querySecurityEvents(
    SecurityEventQuery query,
  ) async => [];

  @override
  Future<bool> transitionState(
    String deviceId,
    TrustState from,
    TrustState to, {
    DateTime? pairedAt,
  }) async => true;

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}

  @override
  Future<void> updateDisplayName(String deviceId, String displayName) async {}

  @override
  Future<void> upsertPeer(PeerRecord record) async {
    _peers[record.deviceId] = record;
  }
}

PeerRecord _peer(String deviceId, TrustState state) => PeerRecord(
  deviceId: deviceId,
  certDer: Uint8List(0),
  state: state,
  updatedAt: DateTime.utc(2026, 7, 13),
);

void main() {
  group('allowPeerHandshake', () {
    test('allows unknown peer', () async {
      final trustStore = _FakeTrustStore();

      final allowed = await allowPeerHandshake(
        trustStore: trustStore,
        peerDeviceId: 'rift-unknown-peer',
      );

      expect(allowed, isTrue);
      expect(trustStore.deletedPeers, isEmpty);
    });

    test('rejects blocked peer without deleting record', () async {
      final trustStore = _FakeTrustStore();
      await trustStore.upsertPeer(_peer('rift-blocked-peer', TrustState.blocked));

      final allowed = await allowPeerHandshake(
        trustStore: trustStore,
        peerDeviceId: 'rift-blocked-peer',
      );

      expect(allowed, isFalse);
      expect(await trustStore.getPeer('rift-blocked-peer'), isNotNull);
      expect(trustStore.deletedPeers, isEmpty);
    });

    test('rejects revoked peer and deletes legacy record', () async {
      final trustStore = _FakeTrustStore();
      await trustStore.upsertPeer(_peer('rift-revoked-peer', TrustState.revoked));

      final allowed = await allowPeerHandshake(
        trustStore: trustStore,
        peerDeviceId: 'rift-revoked-peer',
      );

      expect(allowed, isFalse);
      expect(await trustStore.getPeer('rift-revoked-peer'), isNull);
      expect(trustStore.deletedPeers, ['rift-revoked-peer']);
    });
  });
}
