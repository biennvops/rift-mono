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

  /// Peers advertising a device ID hint are tracked by that stable identity
  /// so instance-name churn (advertisers regenerate instance names) shows as
  /// an update instead of a remove+add flap.
  static String trackingKey(DiscoveredPeer peer) =>
      peer.deviceIdHint ?? 'instance:${peer.instanceId}';

  DiscoverySnapshotDelta ingest(Iterable<DiscoveredPeer> peers) {
    final snapshot = <String, DiscoveredPeer>{};
    for (final peer in peers) {
      snapshot[trackingKey(peer)] = peer;
    }

    final removed = <DiscoveredPeer>[];
    final lostIds = _seenPeers.keys.toSet().difference(snapshot.keys.toSet());
    for (final id in lostIds) {
      removed.add(_seenPeers.remove(id)!);
    }

    final added = <DiscoveredPeer>[];
    final updated = <DiscoveredPeer>[];
    for (final entry in snapshot.entries) {
      final existing = _seenPeers[entry.key];
      if (existing == null) {
        _seenPeers[entry.key] = entry.value;
        added.add(entry.value);
        continue;
      }

      if (!_samePeer(existing, entry.value)) {
        _seenPeers[entry.key] = entry.value;
        updated.add(entry.value);
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
