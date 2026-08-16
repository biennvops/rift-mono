import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nsd/nsd.dart' as nsd;
import '../core/rift_log.dart';
import '../interfaces/discovery_service.dart';
import 'discovery_peer_tracker.dart';
import 'fallback_interface_snapshot.dart';

typedef DiscoveryInterfaceEnumerator =
    Future<List<FallbackInterfaceSnapshot>> Function();
typedef DiscoveryNsdRegister =
    Future<nsd.Registration> Function(nsd.Service service);
typedef DiscoveryNsdUnregister =
    Future<void> Function(nsd.Registration registration);
typedef DiscoveryNsdStart = Future<nsd.Discovery> Function(String serviceType);
typedef DiscoveryNsdStop = Future<void> Function(nsd.Discovery discovery);
typedef DiscoveryAdvertiserSocketBinder =
    Future<DiscoveryAdvertiserSocket> Function(InternetAddress address);
typedef DiscoveryFallbackListenerBinder =
    Future<DiscoveryFallbackListener> Function();
typedef DiscoveryPeriodicTimerFactory =
    DiscoveryPeriodicTimer Function(
      Duration interval,
      Future<void> Function() callback,
    );

abstract interface class DiscoveryAdvertiserSocket {
  set broadcastEnabled(bool enabled);

  int send(List<int> buffer, InternetAddress address, int port);

  void close();
}

abstract interface class DiscoveryFallbackListener {
  Stream<Datagram> get datagrams;

  void close();
}

abstract interface class DiscoveryPeriodicTimer {
  void cancel();
}

class _RawDiscoveryAdvertiserSocket implements DiscoveryAdvertiserSocket {
  final RawDatagramSocket _socket;

  _RawDiscoveryAdvertiserSocket(this._socket);

  @override
  set broadcastEnabled(bool enabled) => _socket.broadcastEnabled = enabled;

  @override
  int send(List<int> buffer, InternetAddress address, int port) =>
      _socket.send(buffer, address, port);

  @override
  void close() => _socket.close();
}

class _RawDiscoveryFallbackListener implements DiscoveryFallbackListener {
  final RawDatagramSocket _socket;

  _RawDiscoveryFallbackListener(this._socket);

  @override
  late final Stream<Datagram> datagrams = _socket
      .where((event) => event == RawSocketEvent.read)
      .map((_) => _socket.receive())
      .where((datagram) => datagram != null)
      .cast<Datagram>();

  @override
  void close() => _socket.close();
}

class _DartDiscoveryPeriodicTimer implements DiscoveryPeriodicTimer {
  late final Timer _timer;

  _DartDiscoveryPeriodicTimer(
    Duration interval,
    Future<void> Function() callback,
  ) {
    _timer = Timer.periodic(interval, (_) => unawaited(callback()));
  }

  @override
  void cancel() => _timer.cancel();
}

Future<DiscoveryAdvertiserSocket> _bindRawAdvertiserSocket(
  InternetAddress address,
) async {
  final socket = await RawDatagramSocket.bind(address, 0);
  return _RawDiscoveryAdvertiserSocket(socket);
}

Future<DiscoveryFallbackListener> _bindRawFallbackListener() async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    9141,
    reuseAddress: true,
    reusePort: true,
  );
  return _RawDiscoveryFallbackListener(socket);
}

class DiscoveryServiceImpl implements DiscoveryService {
  final int port;
  final String minVersion;
  final String maxVersion;
  final String? deviceIdHint;
  final String? fingerprintPrefix;
  final String _instanceId;

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  final List<nsd.Registration> _registrationsPendingCleanup = [];
  final List<nsd.Discovery> _discoveriesPendingCleanup = [];
  final _peerStreamController = StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<DiscoveredPeer>.broadcast();
  final DiscoveryPeerTracker _tracker = DiscoveryPeerTracker();

  List<DiscoveryAdvertiserSocket> _fallbackAdvertiserSockets = [];
  DiscoveryPeriodicTimer? _fallbackAdvertiserTimer;
  DiscoveryFallbackListener? _fallbackListener;
  StreamSubscription<Datagram>? _fallbackListenerSub;
  DiscoveryPeriodicTimer? _fallbackCleanupTimer;
  DiscoveryPeriodicTimer? _interfaceRefreshTimer;
  final _fallbackPeers = <String, ({DiscoveredPeer peer, DateTime lastSeen})>{};
  final _fallbackPingTargets = <String, DateTime>{};
  List<FallbackInterfaceSnapshot> _cachedInterfaces = const [];
  DateTime _cachedInterfacesRefreshedAt = DateTime.fromMillisecondsSinceEpoch(
    0,
  );

  final DiscoveryInterfaceEnumerator _enumerateInterfaces;
  final DiscoveryNsdRegister _registerNsd;
  final DiscoveryNsdUnregister _unregisterNsd;
  final DiscoveryNsdStart _startNsd;
  final DiscoveryNsdStop _stopNsd;
  final DiscoveryAdvertiserSocketBinder _bindAdvertiserSocket;
  final DiscoveryFallbackListenerBinder _bindFallbackListener;
  final DiscoveryPeriodicTimerFactory _createPeriodicTimer;

  bool _disposed = false;
  bool _advertising = false;
  bool _discovering = false;
  int _advertisingGeneration = 0;
  int _discoveryGeneration = 0;

  Future<_InterfaceRefreshResult>? _interfaceRefreshFuture;
  Future<void>? _advertisingStartFuture;
  Future<void>? _advertisingStopFuture;
  Future<void>? _advertiserMaintenanceFuture;
  Future<void>? _fallbackRebindFuture;
  Future<void>? _discoveryStartFuture;
  Future<void>? _discoveryStopFuture;
  Future<void>? _discoveryRefreshFuture;
  Future<void>? _disposeFuture;

  DiscoveryServiceImpl({
    required this.port,
    this.minVersion = '0.1-draft',
    this.maxVersion = '0.1-draft',
    this.deviceIdHint,
    this.fingerprintPrefix,
    DiscoveryInterfaceEnumerator? interfaceEnumerator,
    DiscoveryNsdRegister? nsdRegister,
    DiscoveryNsdUnregister? nsdUnregister,
    DiscoveryNsdStart? nsdStart,
    DiscoveryNsdStop? nsdStop,
    DiscoveryAdvertiserSocketBinder? advertiserSocketBinder,
    DiscoveryFallbackListenerBinder? fallbackListenerBinder,
    DiscoveryPeriodicTimerFactory? periodicTimerFactory,
  }) : _instanceId = 'rift-peer-${DateTime.now().millisecondsSinceEpoch}',
       _enumerateInterfaces =
           interfaceEnumerator ??
           FallbackInterfaceSnapshotEnumerator.enumerateIPv4,
       _registerNsd = nsdRegister ?? nsd.register,
       _unregisterNsd = nsdUnregister ?? nsd.unregister,
       _startNsd = nsdStart ?? nsd.startDiscovery,
       _stopNsd = nsdStop ?? nsd.stopDiscovery,
       _bindAdvertiserSocket =
           advertiserSocketBinder ?? _bindRawAdvertiserSocket,
       _bindFallbackListener =
           fallbackListenerBinder ?? _bindRawFallbackListener,
       _createPeriodicTimer =
           periodicTimerFactory ?? _DartDiscoveryPeriodicTimer.new;

  @override
  Future<void> startAdvertising() {
    _throwIfDisposed();
    if (_advertising) {
      return _advertisingStartFuture ?? Future<void>.value();
    }
    if ((_registration != null || _registrationsPendingCleanup.isNotEmpty) &&
        _advertisingStopFuture == null) {
      throw StateError('Advertising teardown must complete before restarting.');
    }

    _advertising = true;
    final generation = ++_advertisingGeneration;
    final stopping = _advertisingStopFuture;
    late final Future<void> startFuture;
    startFuture = _startAdvertisingAfterStop(stopping, generation).whenComplete(
      () {
        if (identical(_advertisingStartFuture, startFuture)) {
          _advertisingStartFuture = null;
        }
      },
    );
    _advertisingStartFuture = startFuture;
    return startFuture;
  }

  Future<void> _startAdvertisingAfterStop(
    Future<void>? stopping,
    int generation,
  ) async {
    try {
      if (stopping != null) {
        await stopping;
      }
      if (!_isAdvertisingGeneration(generation)) return;

      await _startAdvertisingLifecycle(generation);
    } catch (_) {
      if (_isAdvertisingGeneration(generation)) {
        _advertising = false;
        _advertisingGeneration++;
      }
      rethrow;
    }
  }

  Future<void> _startAdvertisingLifecycle(int generation) async {
    final registration = await _registerNsd(
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
    if (!_isAdvertisingGeneration(generation)) {
      await _discardStaleRegistration(registration);
      return;
    }
    _registration = registration;

    await _startFallbackAdvertiser(generation);
  }

  Future<void> _startFallbackAdvertiser(int generation) async {
    try {
      await _refreshInterfacesSingleFlight(force: true);
      if (!_isAdvertisingGeneration(generation)) return;

      await _rebindFallbackAdvertiserSocketsSingleFlight(generation);
      if (!_isAdvertisingGeneration(generation)) return;

      final bytes = utf8.encode(
        jsonEncode({
          'rift': '0.1-draft',
          'kind': 'fallback-discovery',
          'instanceId': _instanceId,
          'port': port,
          'minV': minVersion,
          'maxV': maxVersion,
          'did': deviceIdHint,
          if (fingerprintPrefix != null) 'fp': fingerprintPrefix,
        }),
      );
      final timer = _createPeriodicTimer(
        const Duration(seconds: 2),
        () => _runAdvertiserMaintenanceSingleFlight(generation, bytes),
      );
      if (!_isAdvertisingGeneration(generation)) {
        timer.cancel();
        return;
      }
      _fallbackAdvertiserTimer = timer;
    } catch (error) {
      RiftLog.warn(
        '[Discovery] Failed to bind UDP Fallback Advertiser: $error',
      );
    }
  }

  Future<void> _runAdvertiserMaintenanceSingleFlight(
    int generation,
    List<int> bytes,
  ) {
    if (!_isAdvertisingGeneration(generation)) {
      return Future<void>.value();
    }
    final active = _advertiserMaintenanceFuture;
    if (active != null) return active;

    late final Future<void> maintenanceFuture;
    maintenanceFuture = _runAdvertiserMaintenance(generation, bytes)
        .whenComplete(() {
          if (identical(_advertiserMaintenanceFuture, maintenanceFuture)) {
            _advertiserMaintenanceFuture = null;
          }
        });
    _advertiserMaintenanceFuture = maintenanceFuture;
    return maintenanceFuture;
  }

  Future<void> _runAdvertiserMaintenance(
    int generation,
    List<int> bytes,
  ) async {
    try {
      final interfaceRefresh = await _refreshInterfacesSingleFlight();
      if (!_isAdvertisingGeneration(generation)) return;

      if (interfaceRefresh.changed) {
        await _rebindFallbackAdvertiserSocketsSingleFlight(generation);
      }
      if (!_isAdvertisingGeneration(generation)) return;

      final sockets = List<DiscoveryAdvertiserSocket>.of(
        _fallbackAdvertiserSockets,
      );
      for (final socket in sockets) {
        socket.send(bytes, InternetAddress('255.255.255.255'), 9141);
      }

      final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
      final expiredTargets = <String>[];
      for (final entry in _fallbackPingTargets.entries) {
        if (entry.value.isBefore(cutoff)) {
          expiredTargets.add(entry.key);
          continue;
        }

        for (final socket in sockets) {
          socket.send(bytes, InternetAddress(entry.key), 9141);
        }
      }
      for (final address in expiredTargets) {
        _fallbackPingTargets.remove(address);
      }
    } catch (error) {
      RiftLog.debug('[Discovery] UDP Fallback broadcast failed: $error');
      if (_isAdvertisingGeneration(generation)) {
        _cachedInterfacesRefreshedAt = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
  }

  @override
  Future<void> stopAdvertising() {
    _advertising = false;
    _advertisingGeneration++;
    _fallbackAdvertiserTimer?.cancel();
    _fallbackAdvertiserTimer = null;

    final existingStop = _advertisingStopFuture;
    if (existingStop != null) return existingStop;

    final sockets = _fallbackAdvertiserSockets;
    _fallbackAdvertiserSockets = [];
    final ownedWork = <Future<void>?>[
      _advertisingStartFuture,
      _advertiserMaintenanceFuture,
      _fallbackRebindFuture,
    ];

    late final Future<void> stopFuture;
    stopFuture = _finishStopAdvertising(sockets, ownedWork).whenComplete(() {
      if (identical(_advertisingStopFuture, stopFuture)) {
        _advertisingStopFuture = null;
      }
    });
    _advertisingStopFuture = stopFuture;
    return stopFuture;
  }

  Future<void> _finishStopAdvertising(
    List<DiscoveryAdvertiserSocket> sockets,
    List<Future<void>?> ownedWork,
  ) async {
    for (final socket in sockets) {
      socket.close();
    }
    await Future.wait([
      for (final work in ownedWork)
        if (work != null) _ignoreErrors(work),
    ]);

    await _unregisterPendingRegistrations();
    final registration = _registration;
    if (registration != null) {
      await _unregisterCurrentRegistration(registration);
    }
  }

  @override
  Stream<DiscoveredPeer> get onDeviceDiscovered => _peerStreamController.stream;

  @override
  Stream<DiscoveredPeer> get onDeviceLost => _peerLostController.stream;

  @override
  Future<void> startDiscovery() {
    _throwIfDisposed();
    if (_discovering) {
      return _discoveryStartFuture ?? Future<void>.value();
    }
    if ((_discovery != null || _discoveriesPendingCleanup.isNotEmpty) &&
        _discoveryStopFuture == null) {
      throw StateError('Discovery teardown must complete before restarting.');
    }

    _discovering = true;
    final generation = ++_discoveryGeneration;
    final stopping = _discoveryStopFuture;
    late final Future<void> startFuture;
    startFuture = _startDiscoveryAfterStop(stopping, generation).whenComplete(
      () {
        if (identical(_discoveryStartFuture, startFuture)) {
          _discoveryStartFuture = null;
        }
      },
    );
    _discoveryStartFuture = startFuture;
    return startFuture;
  }

  Future<void> _startDiscoveryAfterStop(
    Future<void>? stopping,
    int generation,
  ) async {
    try {
      if (stopping != null) {
        await stopping;
      }
      if (!_isDiscoveryGeneration(generation)) return;

      await _startDiscoveryLifecycle(generation);
    } catch (_) {
      if (_isDiscoveryGeneration(generation)) {
        _discovering = false;
        _discoveryGeneration++;
      }
      rethrow;
    }
  }

  Future<void> _startDiscoveryLifecycle(int generation) async {
    await _startNsdDiscovery(generation);
    if (!_isDiscoveryGeneration(generation)) return;

    await _startFallbackListener(generation);
    if (!_isDiscoveryGeneration(generation)) return;

    final refreshTimer = _createPeriodicTimer(
      const Duration(seconds: 30),
      () => _runDiscoveryRefreshSingleFlight(generation),
    );
    if (!_isDiscoveryGeneration(generation)) {
      refreshTimer.cancel();
      return;
    }
    _interfaceRefreshTimer = refreshTimer;
  }

  Future<void> _runDiscoveryRefreshSingleFlight(int generation) {
    if (!_isDiscoveryGeneration(generation)) {
      return Future<void>.value();
    }
    final active = _discoveryRefreshFuture;
    if (active != null) return active;

    late final Future<void> refreshFuture;
    refreshFuture = _refreshInterfacesAndDiscovery(generation).whenComplete(() {
      if (identical(_discoveryRefreshFuture, refreshFuture)) {
        _discoveryRefreshFuture = null;
      }
    });
    _discoveryRefreshFuture = refreshFuture;
    return refreshFuture;
  }

  Future<void> _refreshInterfacesAndDiscovery(int generation) async {
    try {
      final interfaceRefresh = await _refreshInterfacesSingleFlight(
        force: true,
      );
      if (!_isDiscoveryGeneration(generation) || !interfaceRefresh.changed) {
        return;
      }

      RiftLog.info(
        '[Discovery] Network interfaces changed; refreshing discovery.',
      );
      if (!_isDiscoveryGeneration(generation)) return;

      final discovery = _discovery;
      if (discovery != null) {
        await _stopCurrentDiscovery(discovery);
      }
      if (!_isDiscoveryGeneration(generation)) return;

      await _startNsdDiscovery(generation);
    } catch (error) {
      RiftLog.debug('[Discovery] Interface refresh failed: $error');
    }
  }

  Future<void> _startNsdDiscovery(int generation) async {
    nsd.Discovery discovery;
    try {
      discovery = await _startNsd(
        '_rift._tcp',
      ).timeout(const Duration(seconds: 10));
    } catch (error) {
      RiftLog.warn('NSD discovery failed or timed out: $error');
      return;
    }

    if (!_isDiscoveryGeneration(generation)) {
      await _discardStaleDiscovery(discovery);
      return;
    }

    _discovery = discovery;
    discovery.addListener(() {
      if (!_isDiscoveryGeneration(generation) ||
          !identical(_discovery, discovery)) {
        return;
      }

      final snapshot = <DiscoveredPeer>[];
      for (final service in discovery.services) {
        snapshot.addAll(_peersFromNsdService(service));
      }
      _ingestSnapshot(snapshot);
    });
  }

  Future<void> _startFallbackListener(int generation) async {
    try {
      final listener = await _bindFallbackListener();
      if (!_isDiscoveryGeneration(generation)) {
        listener.close();
        return;
      }

      _fallbackListener = listener;
      _fallbackListenerSub = listener.datagrams.listen(
        (datagram) {
          if (_isDiscoveryGeneration(generation) &&
              identical(_fallbackListener, listener)) {
            _handleFallbackPacket(datagram);
          }
        },
        onError: (Object error) {
          if (_isDiscoveryGeneration(generation)) {
            RiftLog.debug('[Discovery] UDP Fallback listener failed: $error');
          }
        },
      );

      final cleanupTimer = _createPeriodicTimer(
        const Duration(seconds: 5),
        () => _runFallbackCleanup(generation),
      );
      if (!_isDiscoveryGeneration(generation)) {
        cleanupTimer.cancel();
        return;
      }
      _fallbackCleanupTimer = cleanupTimer;
    } catch (error) {
      RiftLog.warn('[Discovery] Failed to bind UDP Fallback Listener: $error');
    }
  }

  Future<void> _runFallbackCleanup(int generation) async {
    if (!_isDiscoveryGeneration(generation)) return;

    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _fallbackPeers.entries) {
      if (now.difference(entry.value.lastSeen) > const Duration(seconds: 15)) {
        expired.add(entry.key);
        _peerLostController.add(entry.value.peer);
      }
    }
    for (final id in expired) {
      _fallbackPeers.remove(id);
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
  Future<void> stopDiscovery() {
    _discovering = false;
    _discoveryGeneration++;
    _fallbackCleanupTimer?.cancel();
    _fallbackCleanupTimer = null;
    _interfaceRefreshTimer?.cancel();
    _interfaceRefreshTimer = null;

    final existingStop = _discoveryStopFuture;
    if (existingStop != null) return existingStop;

    final fallbackListener = _fallbackListener;
    _fallbackListener = null;
    final fallbackListenerSub = _fallbackListenerSub;
    _fallbackListenerSub = null;
    _tracker.clear();
    _fallbackPeers.clear();
    _fallbackPingTargets.clear();
    final ownedWork = <Future<void>?>[
      _discoveryStartFuture,
      _discoveryRefreshFuture,
    ];

    late final Future<void> stopFuture;
    stopFuture =
        _finishStopDiscovery(
          fallbackListener,
          fallbackListenerSub,
          ownedWork,
        ).whenComplete(() {
          if (identical(_discoveryStopFuture, stopFuture)) {
            _discoveryStopFuture = null;
          }
        });
    _discoveryStopFuture = stopFuture;
    return stopFuture;
  }

  Future<void> _finishStopDiscovery(
    DiscoveryFallbackListener? fallbackListener,
    StreamSubscription<Datagram>? fallbackListenerSub,
    List<Future<void>?> ownedWork,
  ) async {
    fallbackListener?.close();
    await Future.wait([
      if (fallbackListenerSub != null) fallbackListenerSub.cancel(),
      for (final work in ownedWork)
        if (work != null) _ignoreErrors(work),
    ]);

    await _stopPendingDiscoveries();
    final discovery = _discovery;
    if (discovery != null) {
      await _stopCurrentDiscovery(discovery);
    }
  }

  @override
  Future<void> dispose() {
    final active = _disposeFuture;
    if (active != null) return active;

    late final Future<void> disposeFuture;
    disposeFuture = _dispose().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      if (identical(_disposeFuture, disposeFuture)) {
        _disposeFuture = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
    _disposeFuture = disposeFuture;
    return disposeFuture;
  }

  Future<void> _dispose() async {
    _disposed = true;
    await Future.wait([stopAdvertising(), stopDiscovery()]);
    await _peerStreamController.close();
    await _peerLostController.close();
  }

  Future<_InterfaceRefreshResult> _refreshInterfacesSingleFlight({
    bool force = false,
  }) {
    final active = _interfaceRefreshFuture;
    if (active != null) return active;

    final now = DateTime.now();
    if (!force &&
        _cachedInterfaces.isNotEmpty &&
        now.difference(_cachedInterfacesRefreshedAt) <
            const Duration(seconds: 30)) {
      return Future<_InterfaceRefreshResult>.value(
        _InterfaceRefreshResult(
          previous: _cachedInterfaces,
          current: _cachedInterfaces,
          changed: false,
        ),
      );
    }

    final previous = _cachedInterfaces;
    late final Future<_InterfaceRefreshResult> refreshFuture;
    refreshFuture =
        Future<List<FallbackInterfaceSnapshot>>.sync(_enumerateInterfaces)
            .then((enumerated) {
              final current = List<FallbackInterfaceSnapshot>.unmodifiable(
                enumerated,
              );
              _cachedInterfaces = current;
              _cachedInterfacesRefreshedAt = DateTime.now();
              final result = _InterfaceRefreshResult(
                previous: previous,
                current: current,
                changed: !_sameInterfaceSnapshot(previous, current),
              );
              RiftLog.debug(
                '[Discovery] Refreshed ${current.length} fallback interfaces',
              );
              return result;
            })
            .whenComplete(() {
              if (identical(_interfaceRefreshFuture, refreshFuture)) {
                _interfaceRefreshFuture = null;
              }
            });
    _interfaceRefreshFuture = refreshFuture;
    return refreshFuture;
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

  Future<void> _rebindFallbackAdvertiserSocketsSingleFlight(int generation) {
    if (!_isAdvertisingGeneration(generation)) {
      return Future<void>.value();
    }
    final active = _fallbackRebindFuture;
    if (active != null) return active;

    late final Future<void> rebindFuture;
    rebindFuture = _buildAndInstallFallbackAdvertiserSockets(generation)
        .whenComplete(() {
          if (identical(_fallbackRebindFuture, rebindFuture)) {
            _fallbackRebindFuture = null;
          }
        });
    _fallbackRebindFuture = rebindFuture;
    return rebindFuture;
  }

  Future<void> _buildAndInstallFallbackAdvertiserSockets(int generation) async {
    final replacements = <DiscoveryAdvertiserSocket>[];
    try {
      for (final interface in _cachedInterfaces) {
        DiscoveryAdvertiserSocket? socket;
        try {
          socket = await _bindAdvertiserSocket(
            InternetAddress(interface.address),
          );
          if (!_isAdvertisingGeneration(generation)) {
            socket.close();
            break;
          }
          socket.broadcastEnabled = true;
          replacements.add(socket);
        } catch (error) {
          socket?.close();
          RiftLog.debug(
            '[Discovery] Failed to bind fallback socket for '
            '${interface.interfaceName}/${interface.address}: $error',
          );
        }
      }

      if (replacements.isEmpty && _isAdvertisingGeneration(generation)) {
        final socket = await _bindAdvertiserSocket(InternetAddress.anyIPv4);
        if (!_isAdvertisingGeneration(generation)) {
          socket.close();
        } else {
          socket.broadcastEnabled = true;
          replacements.add(socket);
        }
      }

      if (!_isAdvertisingGeneration(generation)) {
        for (final socket in replacements) {
          socket.close();
        }
        return;
      }

      final previous = _fallbackAdvertiserSockets;
      _fallbackAdvertiserSockets = replacements;
      for (final socket in previous) {
        socket.close();
      }
    } catch (_) {
      for (final socket in replacements) {
        socket.close();
      }
      rethrow;
    }
  }

  bool _isAdvertisingGeneration(int generation) =>
      !_disposed && _advertising && _advertisingGeneration == generation;

  bool _isDiscoveryGeneration(int generation) =>
      !_disposed && _discovering && _discoveryGeneration == generation;

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('DiscoveryServiceImpl has been disposed.');
    }
  }

  Future<void> _unregisterPendingRegistrations() async {
    while (_registrationsPendingCleanup.isNotEmpty) {
      final registration = _registrationsPendingCleanup.first;
      await _unregisterNsd(registration);
      _registrationsPendingCleanup.removeAt(0);
    }
  }

  Future<void> _unregisterCurrentRegistration(
    nsd.Registration registration,
  ) async {
    await _unregisterNsd(registration);
    if (identical(_registration, registration)) {
      _registration = null;
    }
  }

  Future<void> _discardStaleRegistration(nsd.Registration registration) async {
    try {
      await _unregisterNsd(registration);
    } catch (error) {
      _registrationsPendingCleanup.add(registration);
      RiftLog.warn(
        '[Discovery] Failed to unregister stale NSD service; '
        'retaining for retry: $error',
      );
    }
  }

  Future<void> _stopPendingDiscoveries() async {
    while (_discoveriesPendingCleanup.isNotEmpty) {
      final discovery = _discoveriesPendingCleanup.first;
      await _stopNsd(discovery);
      _discoveriesPendingCleanup.removeAt(0);
    }
  }

  Future<void> _stopCurrentDiscovery(nsd.Discovery discovery) async {
    await _stopNsd(discovery);
    if (identical(_discovery, discovery)) {
      _discovery = null;
    }
  }

  Future<void> _discardStaleDiscovery(nsd.Discovery discovery) async {
    try {
      await _stopNsd(discovery);
    } catch (error) {
      _discoveriesPendingCleanup.add(discovery);
      RiftLog.warn(
        '[Discovery] Failed to stop stale NSD discovery; '
        'retaining for retry: $error',
      );
    }
  }

  Future<void> _ignoreErrors(Future<void> work) async {
    try {
      await work;
    } catch (_) {}
  }
}

class _InterfaceRefreshResult {
  final List<FallbackInterfaceSnapshot> previous;
  final List<FallbackInterfaceSnapshot> current;
  final bool changed;

  const _InterfaceRefreshResult({
    required this.previous,
    required this.current,
    required this.changed,
  });
}
