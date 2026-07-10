@Tags(['network'])
library;

import 'dart:async';
import 'package:test/test.dart';
import 'package:mdns_dart/mdns_dart.dart';
import 'package:daemon_dart/src/interfaces/discovery_service.dart';
import 'package:daemon_dart/src/network/discovery_peer_tracker.dart';

void main() {
  group('Discovery Integration (mDNS Network Stack)', () {
    MDNSServer? server;
    StreamSubscription? sub;
    DiscoveryPeerTracker? tracker;
    String? setUpSkipReason;

    setUp(() async {
      setUpSkipReason = null;
      try {
        final service = await MDNSService.create(
          instance: 'rift-peer-1234',
          service: '_rift._tcp',
          port: 12345,
          txt: [
            'minV=0.1-draft',
            'maxV=0.1-draft',
            'did=rift-abcdef1234567890',
          ],
        );
        final config = MDNSServerConfig(zone: service);
        server = MDNSServer(config);
        await server!.start();
        tracker = DiscoveryPeerTracker();
      } catch (e) {
        // Some CI/sandbox environments cannot create multicast sockets.
        setUpSkipReason = 'mDNS multicast not available in this environment: $e';
      }
    });

    tearDown(() async {
      await sub?.cancel();
      server?.stop();
    });

    test('Should discover _rift._tcp service over local network stack', () async {
      if (setUpSkipReason != null) {
        markTestSkipped(setUpSkipReason!);
        return;
      }

      final queryParams = QueryParams(
        service: '_rift._tcp',
        timeout: const Duration(seconds: 5),
      );

      late final Stream<ServiceEntry> stream;
      try {
        stream = await MDNSClient.query(queryParams);
      } catch (e) {
        markTestSkipped('mDNS query not available in this environment: $e');
        return;
      }
      final completer = Completer<ServiceEntry>();

      sub = stream.listen((service) {
        if (service.name.startsWith('rift-peer-1234')) {
          completer.complete(service);
        }
      });

      final discoveredService =
          await completer.future.timeout(const Duration(seconds: 10));
      final delta = tracker!.ingest([
        DiscoveredPeer(
          instanceId: discoveredService.name,
          address: discoveredService.host,
          port: discoveredService.port,
          minVersion: '0.1-draft',
          maxVersion: '0.1-draft',
          deviceIdHint: 'rift-abcdef1234567890',
        ),
      ]);
      final discoveredPeer = delta.added.single;

      expect(discoveredService.port, equals(12345));
      expect(discoveredService.infoFields, contains('minV=0.1-draft'));
      expect(discoveredService.infoFields, contains('did=rift-abcdef1234567890'));
      expect(discoveredPeer.instanceId, startsWith('rift-peer-1234'));
      expect(discoveredPeer.deviceIdHint, equals('rift-abcdef1234567890'));
      expect(discoveredPeer.port, equals(12345));
    });
  });
}
