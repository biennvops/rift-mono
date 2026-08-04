import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nsd/nsd.dart' as nsd;
import '../core/rift_log.dart';
import '../interfaces/discovery_service.dart';
import 'discovery_peer_tracker.dart';
import 'fallback_interface_snapshot.dart';

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

  final _fallbackAdvertiserSockets = <RawDatagramSocket>[];
  Timer? _fallbackAdvertiserTimer;
  RawDatagramSocket? _fallbackListener;
  Timer? _fallbackCleanupTimer;
  Timer? _interfaceRefreshTimer;
  final _fallbackPeers = <String, ({DiscoveredPeer peer, DateTime lastSeen})>{};
  final _fallbackPingTargets = <String, DateTime>{};
  List<FallbackInterfaceSnapshot> _cachedInterfaces = const [];
  DateTime _cachedInterfacesRefreshedAt = DateTime.fromMillisecondsSinceEpoch(
    0,
  );

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

    if (_fallbackAdvertiserSockets.isEmpty) {
      await _refreshCachedInterfacesIfNeeded(force: true);
      await _startFallbackAdvertiser();
    }
  }

  Future<void> _startFallbackAdvertiser() async {
    try {
      await _bindFallbackAdvertiserSockets();

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
      final bytes = utf8.encode(payload);

      _fallbackAdvertiserTimer = Timer.periodic(const Duration(seconds: 2), (
        _,
      ) async {
        try {
          final interfacesChanged = await _refreshCachedInterfacesIfNeeded();
          if (interfacesChanged) {
            await _bindFallbackAdvertiserSockets();
          }

          // Bind one socket to each eligible interface so the OS routes the
          // broadcast through every active LAN, hotspot, or Wi-Fi path.
          for (final socket in _fallbackAdvertiserSockets) {
            socket.send(bytes, InternetAddress('255.255.255.255'), 9141);
          }

          // Reuse recently observed fallback peers as unicast targets to keep
          // hotspot discovery working without relying on incorrect /24 guesses.
          final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
          final expiredTargets = <String>[];
          for (final entry in _fallbackPingTargets.entries) {
            if (entry.value.isBefore(cutoff)) {
              expiredTargets.add(entry.key);
              continue;
            }

            for (final socket in _fallbackAdvertiserSockets) {
              socket.send(bytes, InternetAddress(entry.key), 9141);
            }
          }
          for (final address in expiredTargets) {
            _fallbackPingTargets.remove(address);
          }
        } catch (e) {
          RiftLog.debug('[Discovery] UDP Fallback broadcast failed: $e');
          _cachedInterfacesRefreshedAt = DateTime.fromMillisecondsSinceEpoch(0);
        }
      });
    } catch (e) {
      RiftLog.warn('[Discovery] Failed to bind UDP Fallback Advertiser: $e');
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (_registration != null) {
      await nsd.unregister(_registration!);
      _registration = null;
    }
    _fallbackAdvertiserTimer?.cancel();
    _fallbackAdvertiserTimer = null;
    for (final socket in _fallbackAdvertiserSockets) {
      socket.close();
    }
    _fallbackAdvertiserSockets.clear();
  }

  @override
  Stream<DiscoveredPeer> get onDeviceDiscovered => _peerStreamController.stream;

  @override
  Stream<DiscoveredPeer> get onDeviceLost => _peerLostController.stream;

  @override
  Future<void> startDiscovery() async {
    if (_discovery == null) {
      await _startNsdDiscovery();
    }

    if (_fallbackListener == null) {
      await _startFallbackListener();
    }
    _interfaceRefreshTimer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_refreshInterfacesAndDiscovery()),
    );
  }

  Future<void> _refreshInterfacesAndDiscovery() async {
    try {
      final previous = _cachedInterfaces;
      final current = await FallbackInterfaceSnapshotEnumerator.enumerateIPv4();
      _cachedInterfaces = current;
      _cachedInterfacesRefreshedAt = DateTime.now();
      if (_sameInterfaceSnapshot(previous, current)) {
        return;
      }

      RiftLog.info(
        '[Discovery] Network interfaces changed; refreshing discovery.',
      );
      final discovery = _discovery;
      if (discovery != null) {
        await nsd.stopDiscovery(discovery);
        _discovery = null;
      }
      await _startNsdDiscovery();
    } catch (e) {
      RiftLog.debug('[Discovery] Interface refresh failed: $e');
    }
  }

  Future<void> _startNsdDiscovery() async {
    try {
      _discovery = await nsd
          .startDiscovery('_rift._tcp')
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      RiftLog.warn('NSD discovery failed or timed out: $e');
      _discovery = null;
    }
    if (_discovery != null) {
      _discovery!.addListener(() {
        final snapshot = <DiscoveredPeer>[];
        for (final service in _discovery!.services) {
          snapshot.addAll(_peersFromNsdService(service));
        }
        _ingestSnapshot(snapshot);
      });
    }
  }

  Future<void> _startFallbackListener() async {
    try {
      _fallbackListener = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        9141,
        reuseAddress: true,
        reusePort: true,
      );
      _fallbackListener!.listen((RawSocketEvent e) {
        if (e == RawSocketEvent.read) {
          final d = _fallbackListener!.receive();
          if (d == null) return;
          _handleFallbackPacket(d);
        }
      });

      _fallbackCleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final now = DateTime.now();
        final expired = <String>[];
        for (final entry in _fallbackPeers.entries) {
          if (now.difference(entry.value.lastSeen) >
              const Duration(seconds: 15)) {
            expired.add(entry.key);
            _peerLostController.add(entry.value.peer);
          }
        }
        for (final id in expired) {
          _fallbackPeers.remove(id);
        }
      });
    } catch (e) {
      RiftLog.warn('[Discovery] Failed to bind UDP Fallback Listener: $e');
    }
  }

  void _handleFallbackPacket(Datagram d) {
    try {
      final payload = utf8.decode(d.data);
      final json = jsonDecode(payload) as Map<String, dynamic>;
      if (json['kind'] != 'fallback-discovery') return;

      final instanceId = json['instanceId'];
      if (instanceId == _instanceId || instanceId == null) {
        return;
      }

      final peer = DiscoveredPeer(
        instanceId: instanceId,
        address: d.address.address,
        port: json['port'] ?? 9140,
        minVersion: json['minV'] ?? '0.1-draft',
        maxVersion: json['maxV'] ?? '0.1-draft',
        deviceIdHint: json['did'],
        fingerprintPrefix: json['fp'],
      );

      final existing = _fallbackPeers[instanceId];
      _fallbackPeers[instanceId] = (peer: peer, lastSeen: DateTime.now());
      _fallbackPingTargets[d.address.address] = DateTime.now();

      if (existing == null ||
          existing.peer.address != peer.address ||
          existing.peer.port != peer.port) {
        _peerStreamController.add(peer);
      }
    } catch (e) {
      RiftLog.debug('[Discovery] Failed to parse fallback UDP packet: $e');
    }
  }

  List<DiscoveredPeer> _peersFromNsdService(nsd.Service service) {
    final instanceId = service.name;
    // Skip services without a name — using a fallback would collapse all
    // null-named peers into one dedup entry and suppress re-discovery.
    final port = service.port;
    if (instanceId == null || port == null || instanceId == _instanceId) {
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
    _fallbackCleanupTimer?.cancel();
    _fallbackCleanupTimer = null;
    _interfaceRefreshTimer?.cancel();
    _interfaceRefreshTimer = null;
    _fallbackListener?.close();
    _fallbackListener = null;
    _fallbackPeers.clear();
    _fallbackPingTargets.clear();
  }

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await _peerStreamController.close();
    await _peerLostController.close();
  }

  Future<bool> _refreshCachedInterfacesIfNeeded({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _cachedInterfaces.isNotEmpty &&
        now.difference(_cachedInterfacesRefreshedAt) <
            const Duration(seconds: 30)) {
      return false;
    }

    final previous = _cachedInterfaces;
    _cachedInterfaces =
        await FallbackInterfaceSnapshotEnumerator.enumerateIPv4();
    _cachedInterfacesRefreshedAt = now;
    final changed = !_sameInterfaceSnapshot(previous, _cachedInterfaces);
    RiftLog.debug(
      '[Discovery] Refreshed ${_cachedInterfaces.length} fallback interfaces',
    );
    return changed;
  }

  static bool _sameInterfaceSnapshot(
    List<FallbackInterfaceSnapshot> left,
    List<FallbackInterfaceSnapshot> right,
  ) {
    final leftKeys = left
        .map((item) => '${item.interfaceName}|${item.address}')
        .toSet();
    final rightKeys = right
        .map((item) => '${item.interfaceName}|${item.address}')
        .toSet();
    return leftKeys.length == rightKeys.length &&
        leftKeys.containsAll(rightKeys);
  }

  Future<void> _bindFallbackAdvertiserSockets() async {
    for (final socket in _fallbackAdvertiserSockets) {
      socket.close();
    }
    _fallbackAdvertiserSockets.clear();

    for (final interface in _cachedInterfaces) {
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress(interface.address),
          0,
        );
        socket.broadcastEnabled = true;
        _fallbackAdvertiserSockets.add(socket);
      } catch (e) {
        RiftLog.debug(
          '[Discovery] Failed to bind fallback socket for ${interface.interfaceName}/${interface.address}: $e',
        );
      }
    }

    if (_fallbackAdvertiserSockets.isEmpty) {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      _fallbackAdvertiserSockets.add(socket);
    }
  }
}
