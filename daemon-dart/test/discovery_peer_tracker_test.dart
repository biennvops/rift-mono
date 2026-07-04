import 'package:daemon_dart/src/interfaces/discovery_service.dart';
import 'package:daemon_dart/src/network/discovery_peer_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('DiscoveryPeerTracker', () {
    test('emits updated peer when an existing instance changes address or port',
        () {
      final tracker = DiscoveryPeerTracker();

      final first = DiscoveredPeer(
        instanceId: 'rift-peer-1',
        address: '192.168.1.10',
        port: 11112,
        minVersion: '0.1-draft',
        maxVersion: '0.1-draft',
        deviceIdHint: 'rift-peer-a',
      );
      final second = DiscoveredPeer(
        instanceId: 'rift-peer-1',
        address: '192.168.1.44',
        port: 11113,
        minVersion: '0.1-draft',
        maxVersion: '0.1-draft',
        deviceIdHint: 'rift-peer-a',
      );

      final initialDelta = tracker.ingest([first]);
      final updatedDelta = tracker.ingest([second]);

      expect(initialDelta.added, hasLength(1));
      expect(initialDelta.updated, isEmpty);
      expect(updatedDelta.added, isEmpty);
      expect(updatedDelta.updated, hasLength(1));
      expect(updatedDelta.updated.single.address, '192.168.1.44');
      expect(updatedDelta.updated.single.port, 11113);
    });
  });
}
