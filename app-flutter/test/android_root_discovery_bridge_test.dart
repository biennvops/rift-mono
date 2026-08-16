import 'package:flutter_test/flutter_test.dart';

import 'package:rift/src/ipc/android_root_discovery_bridge.dart';

void main() {
  test('AndroidDiscoveryPeerTracker ingests and computes added/removed deltas',
      () {
    final tracker = AndroidDiscoveryPeerTracker();
    expect(tracker.currentPeers, isEmpty);

    final a = AndroidDiscoveredPeer(
      instanceId: 'a',
      address: '192.168.1.10',
      port: 11112,
      observedEndpoints: const [
        (address: '192.168.1.10', port: 11112),
      ],
      minVersion: '0.1-draft',
      maxVersion: '0.1-draft',
      deviceIdHint: 'rift-a',
      fingerprintPrefix: 'AAAAAAA1',
    );
    final b = AndroidDiscoveredPeer(
      instanceId: 'b',
      address: '192.168.1.11',
      port: 11112,
      observedEndpoints: const [
        (address: '192.168.1.11', port: 11112),
      ],
      minVersion: '0.1-draft',
      maxVersion: '0.1-draft',
      deviceIdHint: null,
    );

    final first = tracker.ingest([a, b]);
    expect(first.added.map((p) => p.instanceId), containsAll(['a', 'b']));
    expect(first.removed, isEmpty);

    final second = tracker.ingest([a]);
    expect(second.added, isEmpty);
    expect(second.removed.single.instanceId, 'b');
  });

  test('AndroidDiscoveredPeer toIpcMap includes did/fp when present', () {
    final peer = AndroidDiscoveredPeer(
      instanceId: 'inst',
      address: '192.168.1.10',
      port: 9140,
      observedEndpoints: const [
        (address: '192.168.1.10', port: 9140),
        (address: 'fe80::1234', port: 9140),
      ],
      minVersion: '0.1-draft',
      maxVersion: '0.1-draft',
      deviceIdHint: 'rift-peer',
      fingerprintPrefix: 'FPFPFPFP',
    );

    final map = peer.toIpcMap();
    expect(map['deviceId'], 'rift-peer');
    expect(map['address'], '192.168.1.10');
    expect(map['port'], 9140);
    expect(map['trustState'], 'discovered');
    expect(map['observedEndpoints'], [
      {'address': '192.168.1.10', 'port': 9140},
      {'address': 'fe80::1234', 'port': 9140},
    ]);
    expect(map['txtRecord']['did'], 'rift-peer');
    expect(map['txtRecord']['fp'], 'FPFPFPFP');
  });
}
