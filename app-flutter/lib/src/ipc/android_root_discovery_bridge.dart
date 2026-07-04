import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

class AndroidDiscoveredPeer {
  final String instanceId;
  final String address;
  final int port;
  final List<({String address, int port})> observedEndpoints;
  final String minVersion;
  final String maxVersion;
  final String? deviceIdHint;
  final String? fingerprintPrefix;

  const AndroidDiscoveredPeer({
    required this.instanceId,
    required this.address,
    required this.port,
    required this.observedEndpoints,
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
      'observedEndpoints': observedEndpoints
          .map(
            (endpoint) => {
              'address': endpoint.address,
              'port': endpoint.port,
            },
          )
          .toList(growable: false),
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
      'observedEndpoints': observedEndpoints
          .map(
            (endpoint) => {
              'address': endpoint.address,
              'port': endpoint.port,
            },
          )
          .toList(growable: false),
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
  final List<AndroidDiscoveredPeer> updated;

  const AndroidDiscoverySnapshotDelta({
    required this.added,
    required this.removed,
    required this.updated,
  });
}

class AndroidRootDiscoveryBridge {
  static const int _fallbackDiscoveryPort = 9141;
  static const Duration _fallbackBeaconInterval = Duration(seconds: 2);
  static const Duration _fallbackPeerTtl = Duration(seconds: 6);

  final int port;
  final String deviceIdHint;
  final String? fingerprintPrefix;
  final String minVersion;
  final String maxVersion;

  final _peerDiscoveredController =
      StreamController<AndroidDiscoveredPeer>.broadcast();
  final _peerLostController =
      StreamController<AndroidDiscoveredPeer>.broadcast();
  final AndroidDiscoveryPeerTracker tracker = AndroidDiscoveryPeerTracker();

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  RawDatagramSocket? _fallbackAdvertiserSocket;
  Timer? _fallbackAdvertiserTimer;
  RawDatagramSocket? _fallbackDiscoverySocket;
  Timer? _fallbackPeerPruneTimer;
  final Map<String, ({AndroidDiscoveredPeer peer, DateTime lastSeen})>
      _fallbackPeersByInstanceId = {};
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
    return tracker.currentPeers
        .where((peer) => peer.deviceIdHint != null)
        .map((peer) => peer.toIpcMap())
        .toList(growable: false);
  }

  List<Map<String, dynamic>> listPeersForDaemonControl() {
    return tracker.currentPeers
        .map((peer) => peer.toDaemonControlMap())
        .toList(growable: false);
  }

  Future<void> ensureAdvertising() async {
    if (_registration != null) {
      await _ensureFallbackAdvertising();
      return;
    }

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
      debugPrint(
          '[mDNS Error] Failed to register service (advertising disabled): $e');
    }

    await _ensureFallbackAdvertising();
  }

  Future<void> startDiscovery() async {
    if (_discovery != null) return;

    _discovery = await nsd.startDiscovery('_rift._tcp');
    _discovery!.addListener(_onDiscoveryChanged);
    await _ensureFallbackDiscovery();
  }

  Future<void> stopDiscovery() async {
    if (_discovery == null) return;

    final discovery = _discovery!;
    _discovery = null;
    discovery.removeListener(_onDiscoveryChanged);
    try {
      await nsd.stopDiscovery(discovery);
    } catch (e) {
      if (!_isBenignStopDiscoveryError(e)) {
        rethrow;
      }
      debugPrint('[mDNS Debug] Ignoring benign stopDiscovery error: $e');
    }

    final cleared = tracker.clear();
    _fallbackPeersByInstanceId.clear();
    _fallbackPeerPruneTimer?.cancel();
    _fallbackPeerPruneTimer = null;
    _fallbackDiscoverySocket?.close();
    _fallbackDiscoverySocket = null;
    for (final peer in cleared) {
      _peerLostController.add(peer);
    }
  }

  Future<void> dispose() async {
    await stopDiscovery();
    _fallbackAdvertiserTimer?.cancel();
    _fallbackAdvertiserTimer = null;
    _fallbackAdvertiserSocket?.close();
    _fallbackAdvertiserSocket = null;
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

    debugPrint(
        '[mDNS Debug] nsd plugin fired _onDiscoveryChanged with ${discovery.services.length} services.');
    final mdnsSnapshot = <AndroidDiscoveredPeer>[];
    for (final service in discovery.services) {
      debugPrint(
          '[mDNS Debug] nsd raw service: name=${service.name}, type=${service.type}, host=${service.host}, addresses=${service.addresses}, port=${service.port}, txt=${service.txt}');
      final peer = _peerFromService(service);
      if (peer != null) {
        debugPrint(
            '[mDNS Debug] Parsed peer: ${peer.instanceId} at ${peer.address}:${peer.port}');
        if (peer.deviceIdHint != deviceIdHint) {
          if (_shouldSuppressMdnsPeer(peer)) {
            debugPrint(
              '[mDNS Debug] Suppressed stale mDNS peer: ${peer.instanceId} '
              'at ${peer.address}:${peer.port}',
            );
            continue;
          }
          mdnsSnapshot.add(peer);
        } else {
          debugPrint('[mDNS Debug] Ignored self peer.');
        }
      } else {
        debugPrint(
            '[mDNS Debug] Failed to parse peer from service: ${service.name}');
      }
    }
    _ingestMergedSnapshot(mdnsSnapshot);
  }

  void _ingestMergedSnapshot(
      [Iterable<AndroidDiscoveredPeer> mdnsSnapshot = const []]) {
    final mergedByInstanceId = <String, AndroidDiscoveredPeer>{
      for (final peer in mdnsSnapshot) peer.instanceId: peer,
      for (final entry in _fallbackPeersByInstanceId.entries)
        if (entry.value.peer.deviceIdHint != deviceIdHint)
          entry.key: entry.value.peer,
    };

    final delta = tracker.ingest(mergedByInstanceId.values);
    for (final peer in delta.removed) {
      _peerLostController.add(peer);
    }
    for (final peer in delta.added) {
      _peerDiscoveredController.add(peer);
    }
    for (final peer in delta.updated) {
      debugPrint(
        '[mDNS Debug] Updated peer: ${peer.instanceId} now at ${peer.address}:${peer.port}',
      );
      _peerDiscoveredController.add(peer);
    }
  }

  AndroidDiscoveredPeer? _peerFromService(nsd.Service service) {
    final instanceId = service.name;
    final port = service.port;
    final observedEndpoints = <({String address, int port})>[];
    final seenAddresses = <String>{};

    for (final candidate in service.addresses ?? const <InternetAddress>[]) {
      final address = candidate.address;
      if (seenAddresses.add(address)) {
        observedEndpoints.add((address: address, port: port ?? 0));
      }
    }

    final host = service.host;
    if (host != null && seenAddresses.add(host)) {
      observedEndpoints.add((address: host, port: port ?? 0));
    }

    if (instanceId == null || port == null || observedEndpoints.isEmpty) {
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
      address: observedEndpoints.first.address,
      port: port,
      observedEndpoints: observedEndpoints,
      minVersion: minV,
      maxVersion: maxV,
      deviceIdHint: did,
      fingerprintPrefix: fp,
    );
  }

  bool _isBenignStopDiscoveryError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('stopdiscovery') &&
        message.contains('multicastlock under-locked');
  }

  Future<void> _ensureFallbackAdvertising() async {
    if (_fallbackAdvertiserSocket != null) {
      return;
    }

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      socket.broadcastEnabled = true;
      _fallbackAdvertiserSocket = socket;
      _sendFallbackBeacon();
      _fallbackAdvertiserTimer = Timer.periodic(
        _fallbackBeaconInterval,
        (_) => _sendFallbackBeacon(),
      );
    } catch (e) {
      debugPrint('[mDNS Debug] Failed to start UDP fallback advertising: $e');
    }
  }

  Future<void> _ensureFallbackDiscovery() async {
    if (_fallbackDiscoverySocket != null) {
      return;
    }

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _fallbackDiscoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      _fallbackDiscoverySocket = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final datagram = socket.receive();
        if (datagram == null) {
          return;
        }
        _handleFallbackDatagram(datagram);
      });
      _fallbackPeerPruneTimer ??= Timer.periodic(
        _fallbackBeaconInterval,
        (_) => _pruneExpiredFallbackPeers(),
      );
    } catch (e) {
      debugPrint('[mDNS Debug] Failed to start UDP fallback discovery: $e');
    }
  }

  void _handleFallbackDatagram(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      if (decoded['kind'] != 'fallback-discovery' ||
          decoded['rift'] != '0.1-draft') {
        return;
      }

      final instanceId = decoded['instanceId'];
      final port = decoded['port'];
      final minVersion = decoded['minV'];
      final maxVersion = decoded['maxV'];
      if (instanceId is! String ||
          port is! int ||
          minVersion is! String ||
          maxVersion is! String) {
        return;
      }

      final did = decoded['did'] as String?;
      if (did == null || did == deviceIdHint) {
        return;
      }

      final peer = AndroidDiscoveredPeer(
        instanceId: instanceId,
        address: datagram.address.address,
        port: port,
        observedEndpoints: [
          (address: datagram.address.address, port: port),
        ],
        minVersion: minVersion,
        maxVersion: maxVersion,
        deviceIdHint: did,
        fingerprintPrefix: decoded['fp'] as String?,
      );

      _fallbackPeersByInstanceId[instanceId] = (
        peer: peer,
        lastSeen: DateTime.now(),
      );
      debugPrint(
        '[mDNS Debug] Parsed fallback peer: ${peer.instanceId} at ${peer.address}:${peer.port}',
      );
      _ingestMergedSnapshot();
    } catch (e) {
      debugPrint('[mDNS Debug] Ignoring malformed UDP fallback packet: $e');
    }
  }

  bool _shouldSuppressMdnsPeer(AndroidDiscoveredPeer peer) {
    final deviceId = peer.deviceIdHint;
    if (deviceId == null) {
      return false;
    }

    final freshFallbackPeer = _freshFallbackPeerForDeviceId(deviceId);
    if (freshFallbackPeer == null) {
      return false;
    }

    return freshFallbackPeer.address != peer.address ||
        freshFallbackPeer.port != peer.port;
  }

  AndroidDiscoveredPeer? _freshFallbackPeerForDeviceId(String deviceId) {
    final cutoff = DateTime.now().subtract(_fallbackPeerTtl);
    for (final entry in _fallbackPeersByInstanceId.values) {
      if (entry.lastSeen.isBefore(cutoff)) {
        continue;
      }
      final peer = entry.peer;
      if (peer.deviceIdHint == deviceId) {
        return peer;
      }
    }
    return null;
  }

  void _pruneExpiredFallbackPeers() {
    if (_fallbackPeersByInstanceId.isEmpty) {
      return;
    }

    final cutoff = DateTime.now().subtract(_fallbackPeerTtl);
    final expiredIds = _fallbackPeersByInstanceId.entries
        .where((entry) => entry.value.lastSeen.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList(growable: false);

    if (expiredIds.isEmpty) {
      return;
    }

    for (final id in expiredIds) {
      _fallbackPeersByInstanceId.remove(id);
    }
    _ingestMergedSnapshot();
  }

  void _sendFallbackBeacon() {
    final socket = _fallbackAdvertiserSocket;
    if (socket == null) {
      return;
    }

    final payload = jsonEncode({
      'rift': '0.1-draft',
      'kind': 'fallback-discovery',
      'instanceId': _instanceId,
      'port': port,
      'minV': minVersion,
      'maxV': maxVersion,
      'did': deviceIdHint,
      if (fingerprintPrefix != null) 'fp': fingerprintPrefix,
    });

    socket.send(
      Uint8List.fromList(utf8.encode(payload)),
      InternetAddress('255.255.255.255'),
      _fallbackDiscoveryPort,
    );
  }
}

class AndroidDiscoveryPeerTracker {
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
    final updated = <AndroidDiscoveredPeer>[];
    for (final peer in snapshot) {
      final existing = _seenPeers[peer.instanceId];
      if (existing == null) {
        _seenPeers[peer.instanceId] = peer;
        added.add(peer);
        continue;
      }

      if (!_samePeer(existing, peer)) {
        _seenPeers[peer.instanceId] = peer;
        updated.add(peer);
      }
    }

    return AndroidDiscoverySnapshotDelta(
      added: added,
      removed: removed,
      updated: updated,
    );
  }

  bool _samePeer(AndroidDiscoveredPeer a, AndroidDiscoveredPeer b) {
    return a.address == b.address &&
        a.port == b.port &&
        listEquals(
          a.observedEndpoints
              .map((endpoint) => '${endpoint.address}:${endpoint.port}')
              .toList(growable: false),
          b.observedEndpoints
              .map((endpoint) => '${endpoint.address}:${endpoint.port}')
              .toList(growable: false),
        ) &&
        a.minVersion == b.minVersion &&
        a.maxVersion == b.maxVersion &&
        a.deviceIdHint == b.deviceIdHint &&
        a.fingerprintPrefix == b.fingerprintPrefix;
  }

  List<AndroidDiscoveredPeer> clear() {
    final removed = _seenPeers.values.toList(growable: false);
    _seenPeers.clear();
    return removed;
  }
}
