import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:nsd/nsd.dart' as nsd;
import '../interfaces/discovery_service.dart';
import 'discovery_peer_tracker.dart';

class DiscoveryServiceImpl implements DiscoveryService {
  final int port;
  final String minVersion;
  final String maxVersion;
  final String? deviceIdHint;
  final String? fingerprintPrefix;
  final String _instanceId;

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  final _peerStreamController = StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<DiscoveredPeer>.broadcast();
  final DiscoveryPeerTracker _tracker = DiscoveryPeerTracker();

  DiscoveryServiceImpl({
    required this.port,
    this.minVersion = '0.1-draft',
    this.maxVersion = '0.1-draft',
    this.deviceIdHint,
    this.fingerprintPrefix,
  }) : _instanceId = 'rift-peer-${DateTime.now().millisecondsSinceEpoch}';

  @override
  Future<void> startAdvertising() async {
    if (_registration != null) return;

    final registration = await nsd.register(
      nsd.Service(
        name: _instanceId,
        type: '_rift._tcp',
        port: port,
        txt: {
          'minV': Uint8List.fromList(minVersion.codeUnits),
          'maxV': Uint8List.fromList(maxVersion.codeUnits),
          if (deviceIdHint != null)
            'did': Uint8List.fromList(deviceIdHint!.codeUnits),
          if (fingerprintPrefix != null)
            'fp': Uint8List.fromList(fingerprintPrefix!.codeUnits),
        },
      ),
    );
    _registration = registration;
  }

  @override
  Future<void> stopAdvertising() async {
    if (_registration != null) {
      await nsd.unregister(_registration!);
      _registration = null;
    }
  }

  @override
  Stream<DiscoveredPeer> get onDeviceDiscovered => _peerStreamController.stream;

  @override
  Stream<DiscoveredPeer> get onDeviceLost => _peerLostController.stream;

  @override
  Future<void> startDiscovery() async {
    if (_discovery != null) return;

    _discovery = await nsd.startDiscovery('_rift._tcp');

    _discovery!.addListener(() {
      final snapshot = <DiscoveredPeer>[];
      for (final service in _discovery!.services) {
        snapshot.addAll(_peersFromNsdService(service));
      }
      _ingestSnapshot(snapshot);
    });
  }

  List<DiscoveredPeer> _peersFromNsdService(nsd.Service service) {
    final instanceId = service.name;
    // Skip services without a name — using a fallback would collapse all
    // null-named peers into one dedup entry and suppress re-discovery.
    final port = service.port;
    if (instanceId == null || port == null) {
      return const [];
    }

    final txt = service.txt ?? {};
    final minV = txt['minV'] != null
        ? String.fromCharCodes(txt['minV']!)
        : 'unknown';
    final maxV = txt['maxV'] != null
        ? String.fromCharCodes(txt['maxV']!)
        : 'unknown';
    final did = txt['did'] != null ? String.fromCharCodes(txt['did']!) : null;
    final fp = txt['fp'] != null ? String.fromCharCodes(txt['fp']!) : null;

    final peers = <DiscoveredPeer>[];
    final seenAddresses = <String>{};

    for (final candidate in service.addresses ?? const <InternetAddress>[]) {
      final address = candidate.address;
      if (!seenAddresses.add(address)) {
        continue;
      }

      peers.add(
        DiscoveredPeer(
          instanceId: peers.isEmpty
              ? instanceId
              : '$instanceId#${peers.length}',
          address: address,
          port: port,
          minVersion: minV,
          maxVersion: maxV,
          deviceIdHint: did,
          fingerprintPrefix: fp,
        ),
      );
    }

    final host = service.host;
    if (host != null && seenAddresses.add(host)) {
      peers.add(
        DiscoveredPeer(
          instanceId: peers.isEmpty
              ? instanceId
              : '$instanceId#${peers.length}',
          address: host,
          port: port,
          minVersion: minV,
          maxVersion: maxV,
          deviceIdHint: did,
          fingerprintPrefix: fp,
        ),
      );
    }

    return peers;
  }

  // Shared dedup/eviction path for the real nsd listener. Integration tests
  // exercise the same behavior through DiscoveryPeerTracker directly so they
  // can stay pure-Dart and avoid depending on the Flutter-only nsd plugin.
  void _ingestSnapshot(Iterable<DiscoveredPeer> peers) {
    final delta = _tracker.ingest(peers);
    for (final peer in delta.removed) {
      _peerLostController.add(peer);
    }
    for (final peer in delta.added) {
      _peerStreamController.add(peer);
    }
    for (final peer in delta.updated) {
      _peerStreamController.add(peer);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    if (_discovery != null) {
      await nsd.stopDiscovery(_discovery!);
      _discovery = null;
      _tracker.clear(); // Reset tracking when discovery stops
    }
  }

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await _peerStreamController.close();
    await _peerLostController.close();
  }
}
