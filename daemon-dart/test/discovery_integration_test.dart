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

    setUp(() async {
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
    });

    tearDown(() async {
      await sub?.cancel();
      server?.stop();
    });

    test('Should discover _rift._tcp service over local network stack', () async {
      final queryParams = QueryParams(
        service: '_rift._tcp',
        timeout: const Duration(seconds: 5),
      );
      
      final stream = await MDNSClient.query(queryParams);
      final completer = Completer<ServiceEntry>();
      
      sub = stream.listen((service) {
        if (service.name.startsWith('rift-peer-1234')) {
          completer.complete(service);
        }
      });

      final discoveredService = await completer.future.timeout(const Duration(seconds: 10));
      final delta = tracker!.ingest([
        DiscoveredPeer(
          instanceId: discoveredService.name,
          address: discoveredService.host ?? '127.0.0.1',
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
