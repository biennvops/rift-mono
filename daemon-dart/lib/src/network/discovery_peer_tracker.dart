import '../interfaces/discovery_service.dart';

class DiscoverySnapshotDelta {
  final List<DiscoveredPeer> added;
  final List<DiscoveredPeer> updated;
  final List<DiscoveredPeer> removed;

  const DiscoverySnapshotDelta({
    required this.added,
    required this.updated,
    required this.removed,
  });
}

class DiscoveryPeerTracker {
  final Map<String, DiscoveredPeer> _seenPeers = {};

  DiscoverySnapshotDelta ingest(Iterable<DiscoveredPeer> peers) {
    final snapshot = peers.toList(growable: false);
    final currentIds = {
      for (final peer in snapshot) peer.instanceId,
    };

    final removed = <DiscoveredPeer>[];
    final lostIds = _seenPeers.keys.toSet().difference(currentIds);
    for (final id in lostIds) {
      removed.add(_seenPeers.remove(id)!);
    }

    final added = <DiscoveredPeer>[];
    final updated = <DiscoveredPeer>[];
    for (final peer in snapshot) {
      final existing = _seenPeers[peer.instanceId];
      if (existing == null) {
        _seenPeers[peer.instanceId] = peer;
        added.add(peer);
        continue;
      }

      if (!_samePeer(existing, peer)) {
        _seenPeers[peer.instanceId] = peer;
        updated.add(peer);
      }
    }

    return DiscoverySnapshotDelta(
      added: added,
      updated: updated,
      removed: removed,
    );
  }

  void clear() {
    _seenPeers.clear();
  }

  bool _samePeer(DiscoveredPeer a, DiscoveredPeer b) {
    return a.address == b.address &&
        a.port == b.port &&
        a.minVersion == b.minVersion &&
        a.maxVersion == b.maxVersion &&
        a.deviceIdHint == b.deviceIdHint &&
        a.fingerprintPrefix == b.fingerprintPrefix;
  }
}
