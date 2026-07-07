import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nsd/nsd.dart' as nsd;
import '../core/rift_log.dart';
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

  RawDatagramSocket? _fallbackAdvertiserSocket;
  Timer? _fallbackAdvertiserTimer;
  RawDatagramSocket? _fallbackListener;
  Timer? _fallbackCleanupTimer;
  final _fallbackPeers = <String, ({DiscoveredPeer peer, DateTime lastSeen})>{};

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

    if (_fallbackAdvertiserSocket == null) {
      await _startFallbackAdvertiser();
    }
  }

  Future<void> _startFallbackAdvertiser() async {
    try {
      _fallbackAdvertiserSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      _fallbackAdvertiserSocket!.broadcastEnabled = true;

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
          // 1. Send to global broadcast (might route to mobile data on hotspot)
          _fallbackAdvertiserSocket?.send(
            bytes,
            InternetAddress('255.255.255.255'),
            9141,
          );

          // 2. Iterate network interfaces and send to /24 subnet broadcasts
          // This ensures the packet goes out the WiFi hotspot interface.
          final interfaces = await NetworkInterface.list(
            type: InternetAddressType.IPv4,
          );
          for (final interface in interfaces) {
            for (final addr in interface.addresses) {
              final parts = addr.address.split('.');
              if (parts.length == 4) {
                parts[3] = '255';
                final bcast = parts.join('.');
                _fallbackAdvertiserSocket?.send(
                  bytes,
                  InternetAddress(bcast),
                  9141,
                );
              }
            }
          }
        } catch (e) {
          RiftLog.debug('[Discovery] UDP Fallback broadcast failed: $e');
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
    _fallbackAdvertiserSocket?.close();
    _fallbackAdvertiserSocket = null;
  }

  @override
  Stream<DiscoveredPeer> get onDeviceDiscovered => _peerStreamController.stream;

  @override
  Stream<DiscoveredPeer> get onDeviceLost => _peerLostController.stream;

  @override
  Future<void> startDiscovery() async {
    if (_discovery == null) {
      _discovery = await nsd.startDiscovery('_rift._tcp');
      _discovery!.addListener(() {
        final snapshot = <DiscoveredPeer>[];
        for (final service in _discovery!.services) {
          snapshot.addAll(_peersFromNsdService(service));
        }
        _ingestSnapshot(snapshot);
      });
    }

    if (_fallbackListener == null) {
      await _startFallbackListener();
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
    _fallbackListener?.close();
    _fallbackListener = null;
    _fallbackPeers.clear();
  }

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await _peerStreamController.close();
    await _peerLostController.close();
  }
}
