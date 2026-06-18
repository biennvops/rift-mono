import 'dart:async';
import 'dart:typed_data';
import 'package:nsd/nsd.dart' as nsd;
import '../interfaces/discovery_service.dart';

class DiscoveryServiceImpl implements DiscoveryService {
  final int port;
  final String minVersion;
  final String maxVersion;
  final String _instanceId;

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  final _peerStreamController = StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final Map<String, DiscoveredPeer> _seenPeers = {};

  DiscoveryServiceImpl({
    required this.port,
    this.minVersion = '0.1-draft',
    this.maxVersion = '0.1-draft',
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
  Stream<String> get onDeviceLost => _peerLostController.stream;

  @override
  Future<void> startDiscovery() async {
    if (_discovery != null) return;
    
    _discovery = await nsd.startDiscovery('_rift._tcp');
    
    _discovery!.addListener(() {
      // Compute the set of currently-active instance IDs.
      final currentIds = {
        for (final s in _discovery!.services)
          if (s.name != null) s.name!,
      };

      // Evict removed instances so they can be re-discovered after a mDNS flap.
      final lostIds = _seenPeers.keys.toSet().difference(currentIds);
      for (final id in lostIds) {
        final peer = _seenPeers.remove(id)!;
        _peerLostController.add(peer.deviceIdHint ?? peer.instanceId);
      }

      for (final service in _discovery!.services) {
        final instanceId = service.name;
        // Skip services without a name — using a fallback would collapse all
        // null-named peers into one dedup entry and suppress re-discovery.
        if (instanceId == null || service.host == null || service.port == null) {
          continue;
        }
        if (!_seenPeers.containsKey(instanceId)) {
          final txt = service.txt ?? {};
          final minV = txt['minV'] != null ? String.fromCharCodes(txt['minV']!) : 'unknown';
          final maxV = txt['maxV'] != null ? String.fromCharCodes(txt['maxV']!) : 'unknown';
          final did = txt['did'] != null ? String.fromCharCodes(txt['did']!) : null;
          final fp = txt['fp'] != null ? String.fromCharCodes(txt['fp']!) : null;

          final peer = DiscoveredPeer(
            instanceId: instanceId,
            address: service.host!,
            port: service.port!,
            minVersion: minV,
            maxVersion: maxV,
            deviceIdHint: did,
            fingerprintPrefix: fp,
          );
          _seenPeers[instanceId] = peer;
          _peerStreamController.add(peer);
        }
      }
    });
  }

  @override
  Future<void> stopDiscovery() async {
    if (_discovery != null) {
      await nsd.stopDiscovery(_discovery!);
      _discovery = null;
      _seenPeers.clear(); // Reset tracking when discovery stops
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
