import '../interfaces/discovery_service.dart';

class DiscoverySnapshotDelta {
  final List<DiscoveredPeer> added;
  final List<DiscoveredPeer> removed;

  const DiscoverySnapshotDelta({
    required this.added,
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
    for (final peer in snapshot) {
      if (_seenPeers.containsKey(peer.instanceId)) continue;
      _seenPeers[peer.instanceId] = peer;
      added.add(peer);
    }

    return DiscoverySnapshotDelta(added: added, removed: removed);
  }

  void clear() {
    _seenPeers.clear();
  }
}
