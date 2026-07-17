import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/discovery_service.dart';
import 'package:test/test.dart';

void main() {
  group('RiftDaemon discovered peer selection', () {
    test(
      'listDiscoveredPeers prefers IPv4 primary endpoint but keeps alternates',
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

        final observedEndpoints = (peer['observedEndpoints'] as List)
            .cast<Map<String, dynamic>>();
        expect(observedEndpoints, hasLength(2));
        expect(observedEndpoints.first['address'], '192.168.1.44');
      },
    );

    test(
      'removing one instance keeps peer visible while another instance remains',
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
        final observedEndpoints = (peer['observedEndpoints'] as List)
            .cast<Map<String, dynamic>>();

        expect(peers, hasLength(1));
        expect(observedEndpoints, hasLength(1));
        expect(observedEndpoints.single['address'], '192.168.1.51');
      },
    );

    test(
      'listDiscoveredPeers keeps existing primary for equal score endpoints',
      () async {
        final daemon = RiftDaemon(
          storagePath: '/tmp/rift-daemon-test',
          enableDiscovery: false,
          enableTransport: false,
        );

        daemon.trackDiscoveredPeer(
          DiscoveredPeer(
            instanceId: 'inst-first',
            address: '192.168.1.50',
            port: 11112,
            minVersion: '0.1-draft',
            maxVersion: '0.1-draft',
            deviceIdHint: 'rift-peer-stable-primary',
          ),
        );
        daemon.trackDiscoveredPeer(
          DiscoveredPeer(
            instanceId: 'inst-second',
            address: '10.10.0.20',
            port: 11112,
            minVersion: '0.1-draft',
            maxVersion: '0.1-draft',
            deviceIdHint: 'rift-peer-stable-primary',
          ),
        );

        final peers = await daemon.listDiscoveredPeers();
        final peer = peers.single;
        final observedEndpoints = (peer['observedEndpoints'] as List)
            .cast<Map<String, dynamic>>();

        expect(peer['address'], '192.168.1.50');
        expect(observedEndpoints.first['address'], '192.168.1.50');
        expect(observedEndpoints.last['address'], '10.10.0.20');
      },
    );

    test(
      'replaceExternalDiscoveredPeers expands observedEndpoints into alternates',
      () async {
        final daemon = RiftDaemon(
          storagePath: '/tmp/rift-daemon-test',
          enableDiscovery: false,
          enableTransport: false,
        );

        daemon.replaceExternalDiscoveredPeers([
          {
            'instanceId': 'bridge-peer',
            'address': 'fe80::1234',
            'port': 11112,
            'observedEndpoints': [
              {'address': '192.168.1.77', 'port': 11112},
              {'address': 'fe80::1234', 'port': 11112},
            ],
            'minVersion': '0.1-draft',
            'maxVersion': '0.1-draft',
            'deviceIdHint': 'rift-bridge-peer',
          },
        ], isDiscovering: true);

        final peers = await daemon.listDiscoveredPeers();
        final peer = peers.single;
        final observedEndpoints = (peer['observedEndpoints'] as List)
            .cast<Map<String, dynamic>>();

        expect(peer['deviceId'], 'rift-bridge-peer');
        expect(peer['address'], '192.168.1.77');
        expect(observedEndpoints, hasLength(2));
        expect(observedEndpoints.first['address'], '192.168.1.77');
        expect(observedEndpoints.last['address'], 'fe80::1234');
      },
    );
  });
}
