import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/discovery_service.dart';
import 'package:test/test.dart';

void main() {
  group('RiftDaemon discovered peer selection', () {
    test('listDiscoveredPeers prefers IPv4 primary endpoint but keeps alternates',
        () async {
      final daemon = RiftDaemon(
        storagePath: '/tmp/rift-daemon-test',
        enableDiscovery: false,
        enableTransport: false,
      );

      daemon.trackDiscoveredPeer(
        DiscoveredPeer(
          instanceId: 'inst-v6',
          address: '2405:4802:6a20:e490:f093:96ff:fe22:d512',
          port: 11112,
          minVersion: '0.1-draft',
          maxVersion: '0.1-draft',
          deviceIdHint: 'rift-peer-select',
        ),
      );
      daemon.trackDiscoveredPeer(
        DiscoveredPeer(
          instanceId: 'inst-v4',
          address: '192.168.1.44',
          port: 11112,
          minVersion: '0.1-draft',
          maxVersion: '0.1-draft',
          deviceIdHint: 'rift-peer-select',
        ),
      );

      final peers = await daemon.listDiscoveredPeers();
      final peer = peers.single;

      expect(peer['deviceId'], 'rift-peer-select');
      expect(peer['address'], '192.168.1.44');
      expect(peer['port'], 11112);

      final observedEndpoints =
          (peer['observedEndpoints'] as List).cast<Map<String, dynamic>>();
      expect(observedEndpoints, hasLength(2));
      expect(observedEndpoints.first['address'], '192.168.1.44');
    });

    test('removing one instance keeps peer visible while another instance remains',
        () async {
      final daemon = RiftDaemon(
        storagePath: '/tmp/rift-daemon-test',
        enableDiscovery: false,
        enableTransport: false,
      );

      final first = DiscoveredPeer(
        instanceId: 'inst-a',
        address: '192.168.1.50',
        port: 11112,
        minVersion: '0.1-draft',
        maxVersion: '0.1-draft',
        deviceIdHint: 'rift-peer-multi',
      );
      final second = DiscoveredPeer(
        instanceId: 'inst-b',
        address: '192.168.1.51',
        port: 11112,
        minVersion: '0.1-draft',
        maxVersion: '0.1-draft',
        deviceIdHint: 'rift-peer-multi',
      );

      daemon.trackDiscoveredPeer(first);
      daemon.trackDiscoveredPeer(second);
      daemon.untrackDiscoveredPeer(first);

      final peers = await daemon.listDiscoveredPeers();
      final peer = peers.single;
      final observedEndpoints =
          (peer['observedEndpoints'] as List).cast<Map<String, dynamic>>();

      expect(peers, hasLength(1));
      expect(observedEndpoints, hasLength(1));
      expect(observedEndpoints.single['address'], '192.168.1.51');
    });
  });
}
