import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

class AndroidDiscoveredPeer {
  final String instanceId;
  final String address;
  final int port;
  final String minVersion;
  final String maxVersion;
  final String? deviceIdHint;
  final String? fingerprintPrefix;

  const AndroidDiscoveredPeer({
    required this.instanceId,
    required this.address,
    required this.port,
    required this.minVersion,
    required this.maxVersion,
    this.deviceIdHint,
    this.fingerprintPrefix,
  });

  Map<String, dynamic> toIpcMap() {
    return {
      'deviceId': deviceIdHint,
      'address': address,
      'port': port,
      'trustState': 'discovered',
      'txtRecord': {
        'minV': minVersion,
        'maxV': maxVersion,
        if (deviceIdHint != null) 'did': deviceIdHint,
        if (fingerprintPrefix != null) 'fp': fingerprintPrefix,
      },
    };
  }

  Map<String, dynamic> toDaemonControlMap() {
    return {
      'instanceId': instanceId,
      'address': address,
      'port': port,
      'minVersion': minVersion,
      'maxVersion': maxVersion,
      'deviceIdHint': deviceIdHint,
      'fingerprintPrefix': fingerprintPrefix,
    };
  }
}

class AndroidDiscoverySnapshotDelta {
  final List<AndroidDiscoveredPeer> added;
  final List<AndroidDiscoveredPeer> removed;

  const AndroidDiscoverySnapshotDelta({
    required this.added,
    required this.removed,
  });
}

class AndroidRootDiscoveryBridge {
  final int port;
  final String deviceIdHint;
  final String? fingerprintPrefix;
  final String minVersion;
  final String maxVersion;

  final _peerDiscoveredController =
      StreamController<AndroidDiscoveredPeer>.broadcast();
  final _peerLostController =
      StreamController<AndroidDiscoveredPeer>.broadcast();
  final _tracker = _AndroidDiscoveryPeerTracker();

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  final String _instanceId;

  AndroidRootDiscoveryBridge({
    required this.port,
    required this.deviceIdHint,
    this.fingerprintPrefix,
    this.minVersion = '0.1-draft',
    this.maxVersion = '0.1-draft',
  }) : _instanceId = 'rift-peer-${DateTime.now().millisecondsSinceEpoch}';

  Stream<AndroidDiscoveredPeer> get onPeerDiscovered =>
      _peerDiscoveredController.stream;
  Stream<AndroidDiscoveredPeer> get onPeerLost => _peerLostController.stream;

  bool get isDiscovering => _discovery != null;

  List<Map<String, dynamic>> listPeersForIpc() {
    return _tracker.currentPeers
        .where((peer) => peer.deviceIdHint != null)
        .map((peer) => peer.toIpcMap())
        .toList(growable: false);
  }

  List<Map<String, dynamic>> listPeersForDaemonControl() {
    return _tracker.currentPeers
        .map((peer) => peer.toDaemonControlMap())
        .toList(growable: false);
  }

  Future<void> ensureAdvertising() async {
    if (_registration != null) return;

    try {
      _registration = await nsd.register(
        nsd.Service(
          name: _instanceId,
          type: '_rift._tcp',
          port: port,
          txt: {
            'minV': Uint8List.fromList(minVersion.codeUnits),
            'maxV': Uint8List.fromList(maxVersion.codeUnits),
            'did': Uint8List.fromList(deviceIdHint.codeUnits),
            if (fingerprintPrefix != null)
              'fp': Uint8List.fromList(fingerprintPrefix!.codeUnits),
          },
        ),
      );
    } catch (e) {
      debugPrint('[mDNS Error] Failed to register service (advertising disabled): $e');
    }
  }

  Future<void> startDiscovery() async {
    if (_discovery != null) return;

    _discovery = await nsd.startDiscovery('_rift._tcp');
    _discovery!.addListener(_onDiscoveryChanged);
  }

  Future<void> stopDiscovery() async {
    if (_discovery == null) return;

    final discovery = _discovery!;
    discovery.removeListener(_onDiscoveryChanged);
    await nsd.stopDiscovery(discovery);
    _discovery = null;

    final cleared = _tracker.clear();
    for (final peer in cleared) {
      _peerLostController.add(peer);
    }
  }

  Future<void> dispose() async {
    await stopDiscovery();
    if (_registration != null) {
      await nsd.unregister(_registration!);
      _registration = null;
    }
    await _peerDiscoveredController.close();
    await _peerLostController.close();
  }

  void _onDiscoveryChanged() {
    final discovery = _discovery;
    if (discovery == null) return;

    debugPrint('[mDNS Debug] nsd plugin fired _onDiscoveryChanged with ${discovery.services.length} services.');
    final snapshot = <AndroidDiscoveredPeer>[];
    for (final service in discovery.services) {
      debugPrint('[mDNS Debug] nsd raw service: name=${service.name}, type=${service.type}, host=${service.host}, addresses=${service.addresses}, port=${service.port}, txt=${service.txt}');
      final peer = _peerFromService(service);
      if (peer != null) {
        debugPrint('[mDNS Debug] Parsed peer: ${peer.instanceId} at ${peer.address}:${peer.port}');
        if (peer.deviceIdHint != deviceIdHint) {
          snapshot.add(peer);
        } else {
          debugPrint('[mDNS Debug] Ignored self peer.');
        }
      } else {
        debugPrint('[mDNS Debug] Failed to parse peer from service: ${service.name}');
      }
    }

    final delta = _tracker.ingest(snapshot);
    for (final peer in delta.removed) {
      _peerLostController.add(peer);
    }
    for (final peer in delta.added) {
      _peerDiscoveredController.add(peer);
    }
  }

  AndroidDiscoveredPeer? _peerFromService(nsd.Service service) {
    final instanceId = service.name;
    final address =
        service.host ??
        (service.addresses != null && service.addresses!.isNotEmpty
            ? service.addresses!.first.address
            : null);
    if (instanceId == null || address == null || service.port == null) {
      return null;
    }

    final txt = service.txt ?? {};
    final minV =
        txt['minV'] != null ? String.fromCharCodes(txt['minV']!) : 'unknown';
    final maxV =
        txt['maxV'] != null ? String.fromCharCodes(txt['maxV']!) : 'unknown';
    final did = txt['did'] != null ? String.fromCharCodes(txt['did']!) : null;
    final fp = txt['fp'] != null ? String.fromCharCodes(txt['fp']!) : null;

    return AndroidDiscoveredPeer(
      instanceId: instanceId,
      address: address,
      port: service.port!,
      minVersion: minV,
      maxVersion: maxV,
      deviceIdHint: did,
      fingerprintPrefix: fp,
    );
  }
}

class _AndroidDiscoveryPeerTracker {
  final Map<String, AndroidDiscoveredPeer> _seenPeers = {};

  List<AndroidDiscoveredPeer> get currentPeers =>
      _seenPeers.values.toList(growable: false);

  AndroidDiscoverySnapshotDelta ingest(Iterable<AndroidDiscoveredPeer> peers) {
    final snapshot = peers.toList(growable: false);
    final currentIds = {for (final peer in snapshot) peer.instanceId};

    final removed = <AndroidDiscoveredPeer>[];
    final lostIds = _seenPeers.keys.toSet().difference(currentIds);
    for (final id in lostIds) {
      removed.add(_seenPeers.remove(id)!);
    }

    final added = <AndroidDiscoveredPeer>[];
    for (final peer in snapshot) {
      if (_seenPeers.containsKey(peer.instanceId)) continue;
      _seenPeers[peer.instanceId] = peer;
      added.add(peer);
    }

    return AndroidDiscoverySnapshotDelta(added: added, removed: removed);
  }

  List<AndroidDiscoveredPeer> clear() {
    final removed = _seenPeers.values.toList(growable: false);
    _seenPeers.clear();
    return removed;
  }
}
