import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/ipc/android_daemon_isolate_transport.dart';
import 'package:rift/src/ipc/android_root_discovery_bridge.dart';

void main() {
  group('AndroidDaemonIsolateTransport lifecycle', () {
    test('daemon-ready timeout rolls back the child and attempt resources',
        () async {
      final harness = _TransportHarness([_StartupOutcome.pending]);
      final transport = harness.createTransport(
        readyTimeout: Duration.zero,
      );

      await expectLater(
        transport.connect(),
        throwsA(isA<TimeoutException>()),
      );

      expect(harness.spawnCount, 1);
      expect(harness.killCount, 1);
      expect(harness.liveChildren, 0);
      expect(harness.tlsStartCount, 1);
      expect(harness.tlsDisposeCount, 1);
      expect(transport.hasOwnedDaemonIsolate, isFalse);

      await transport.disconnect();
      expect(harness.killCount, 1);
      await harness.dispose();
    });

    test('retry waits for child exit acknowledgment after kill', () async {
      final harness = _TransportHarness(
        [_StartupOutcome.pending, _StartupOutcome.ready],
        acknowledgeKills: false,
      );
      final transport = harness.createTransport(
        readyTimeout: Duration.zero,
      );

      final firstConnect = transport.connect();
      final firstExpectation = expectLater(
        firstConnect,
        throwsA(isA<TimeoutException>()),
      );
      await pumpEventQueue();
      expect(harness.spawnCount, 1);
      expect(harness.killCount, 1);
      expect(transport.hasOwnedDaemonIsolate, isTrue);

      final joinedConnect = transport.connect();
      final joinedExpectation = expectLater(
        joinedConnect,
        throwsA(isA<TimeoutException>()),
      );
      await pumpEventQueue();
      expect(harness.spawnCount, 1);

      harness.children.first.acknowledgeExit();
      await firstExpectation;
      await joinedExpectation;

      await transport.connect();
      expect(harness.spawnCount, 2);
      expect(harness.liveChildren, 1);
      final disconnect = transport.disconnect();
      harness.children.last.acknowledgeExit();
      await disconnect;
      await harness.dispose();
    });

    test('isolate error before ready rolls back the child', () async {
      final harness = _TransportHarness([_StartupOutcome.error]);
      final transport = harness.createTransport();

      await expectLater(transport.connect(), throwsStateError);

      expect(harness.killCount, 1);
      expect(harness.liveChildren, 0);
      expect(harness.tlsDisposeCount, 1);
      expect(transport.hasOwnedDaemonIsolate, isFalse);
      await harness.dispose();
    });

    test('isolate exit before ready rolls back the child', () async {
      final harness = _TransportHarness([_StartupOutcome.exit]);
      final transport = harness.createTransport();

      await expectLater(transport.connect(), throwsStateError);

      expect(harness.killCount, 1);
      expect(harness.liveChildren, 0);
      expect(harness.tlsDisposeCount, 1);
      expect(transport.hasOwnedDaemonIsolate, isFalse);
      await harness.dispose();
    });

    test('repeated failed starts do not accumulate children', () async {
      final harness = _TransportHarness([
        _StartupOutcome.pending,
        _StartupOutcome.pending,
        _StartupOutcome.pending,
      ]);
      final transport = harness.createTransport(
        readyTimeout: Duration.zero,
      );

      for (var attempt = 0; attempt < 3; attempt += 1) {
        await expectLater(
          transport.connect(),
          throwsA(isA<TimeoutException>()),
        );
      }

      expect(harness.spawnCount, 3);
      expect(harness.killCount, 3);
      expect(harness.liveChildren, 0);
      expect(harness.tlsStartCount, 3);
      expect(harness.tlsDisposeCount, 3);
      expect(transport.hasOwnedDaemonIsolate, isFalse);
      await harness.dispose();
    });

    test('failed starts followed by success leave exactly one child', () async {
      final harness = _TransportHarness([
        _StartupOutcome.pending,
        _StartupOutcome.error,
        _StartupOutcome.ready,
      ]);
      final transport = harness.createTransport(
        readyTimeout: Duration.zero,
      );

      await expectLater(
        transport.connect(),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(transport.connect(), throwsStateError);
      await transport.connect();

      expect(harness.spawnCount, 3);
      expect(harness.killCount, 2);
      expect(harness.liveChildren, 1);
      expect(transport.hasOwnedDaemonIsolate, isTrue);

      await transport.disconnect();
      expect(harness.killCount, 3);
      expect(harness.liveChildren, 0);
      expect(transport.hasOwnedDaemonIsolate, isFalse);
      await harness.dispose();
    });

    test('concurrent connects share one owned child', () async {
      final harness = _TransportHarness([_StartupOutcome.ready]);
      final transport = harness.createTransport();

      await Future.wait([transport.connect(), transport.connect()]);

      expect(harness.spawnCount, 1);
      expect(harness.liveChildren, 1);
      await transport.disconnect();
      expect(harness.killCount, 1);
      await harness.dispose();
    });

    test('disconnect is idempotent and kills the child once', () async {
      final harness = _TransportHarness([_StartupOutcome.ready]);
      final transport = harness.createTransport();
      await transport.connect();

      await Future.wait([
        transport.disconnect(),
        transport.disconnect(),
        transport.disconnect(),
      ]);
      await transport.disconnect();

      expect(harness.killCount, 1);
      expect(harness.tlsDisposeCount, 1);
      expect(harness.liveChildren, 0);
      expect(transport.hasOwnedDaemonIsolate, isFalse);
      await harness.dispose();
    });

    test('disconnect cancels an in-flight connect without resurrection',
        () async {
      final harness = _TransportHarness([_StartupOutcome.pending]);
      final transport = harness.createTransport(
        readyTimeout: const Duration(days: 1),
      );
      final connect = transport.connect();
      final connectExpectation = expectLater(connect, throwsStateError);
      await harness.spawned.future;

      final disconnect = transport.disconnect();
      await connectExpectation;
      await disconnect;

      expect(harness.killCount, 1);
      expect(harness.liveChildren, 0);
      expect(transport.hasOwnedDaemonIsolate, isFalse);
      await harness.dispose();
    });

    test('stale attempt events cannot affect a replacement child', () async {
      final harness = _TransportHarness([
        _StartupOutcome.ready,
        _StartupOutcome.ready,
      ]);
      final transport = harness.createTransport();

      await transport.connect();
      final staleChild = harness.children.single;
      await transport.disconnect();
      await transport.connect();
      expect(harness.liveChildren, 1);

      staleChild.sendReady();
      staleChild.sendError();
      await pumpEventQueue();

      expect(harness.liveChildren, 1);
      expect(harness.killCount, 1);
      expect(transport.hasOwnedDaemonIsolate, isTrue);

      await transport.disconnect();
      expect(harness.liveChildren, 0);
      await harness.dispose();
    });

    test('pending bootstrap requests fail promptly on disconnect', () async {
      final harness = _TransportHarness([_StartupOutcome.ready]);
      final transport = harness.createTransport();
      await transport.connect();
      final requestObserved = harness.rpcRequests.stream.firstWhere(
        (request) => request['method'] == 'rift.testPending',
      );

      final request =
          transport.invokeDaemonBootstrapRpcForTesting('rift.testPending');
      final requestExpectation = expectLater(request, throwsStateError);
      await requestObserved;
      await transport.disconnect();
      await requestExpectation;

      expect(harness.killCount, 1);
      await harness.dispose();
    });

    test('all discovery subscriptions are released on disconnect', () async {
      final discovery = _FakeDiscoveryBridge();
      final harness = _TransportHarness(
        [_StartupOutcome.ready],
        discoveryBridge: discovery,
        includeDiscoveryMetadata: true,
        respondToTrustedPeers: true,
      );
      final transport = harness.createTransport();
      await transport.connect();
      await discovery.allSubscriptionsAttached.future;

      expect(discovery.activeSubscriptions, 3);
      await transport.disconnect();

      expect(discovery.activeSubscriptions, 0);
      expect(discovery.cancelledSubscriptions, 3);
      expect(discovery.disposeCalls, 1);
      await harness.dispose();
    });
  });
}

enum _StartupOutcome { ready, error, exit, pending }

class _TransportHarness {
  _TransportHarness(
    List<_StartupOutcome> outcomes, {
    _FakeDiscoveryBridge? discoveryBridge,
    this.includeDiscoveryMetadata = false,
    this.respondToTrustedPeers = false,
    this.acknowledgeKills = true,
  })  : _outcomes = List<_StartupOutcome>.of(outcomes),
        discoveryBridge = discoveryBridge ?? _FakeDiscoveryBridge();

  final List<_StartupOutcome> _outcomes;
  final _FakeDiscoveryBridge discoveryBridge;
  final bool includeDiscoveryMetadata;
  final bool respondToTrustedPeers;
  final bool acknowledgeKills;
  final List<_FakeChild> children = <_FakeChild>[];
  final List<ReceivePort> _tlsPorts = <ReceivePort>[];
  final StreamController<Map<String, dynamic>> rpcRequests =
      StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> spawned = Completer<void>();
  int spawnCount = 0;
  int killCount = 0;
  int liveChildren = 0;
  int tlsStartCount = 0;
  int tlsDisposeCount = 0;

  AndroidDaemonIsolateTransport createTransport({
    Duration readyTimeout = const Duration(seconds: 1),
  }) {
    return AndroidDaemonIsolateTransport(
      daemonReadyTimeout: readyTimeout,
      bindings: AndroidDaemonTransportBindings(
        loadBootstrap: () async => AndroidDaemonBootstrap(
          storagePath: '/tmp/rift-test',
          identityKey: Uint8List(32),
          rootIsolateToken: Object(),
        ),
        startTlsProxy: _startTlsProxy,
        spawnIsolate: _spawnIsolate,
        createDiscoveryBridge: ({
          required int port,
          required String deviceIdHint,
          String? fingerprintPrefix,
        }) =>
            discoveryBridge,
      ),
    );
  }

  AndroidDaemonTlsProxy _startTlsProxy() {
    tlsStartCount += 1;
    final requests = ReceivePort();
    _tlsPorts.add(requests);
    var disposed = false;
    return AndroidDaemonTlsProxy(
      requestPort: requests.sendPort,
      dispose: () async {
        if (disposed) return;
        disposed = true;
        tlsDisposeCount += 1;
        requests.close();
      },
    );
  }

  Future<void Function()> _spawnIsolate(
    Map<String, dynamic> message, {
    required SendPort onError,
    required SendPort onExit,
  }) {
    spawnCount += 1;
    liveChildren += 1;
    final rpcReceive = ReceivePort();
    final child = _FakeChild(
      uiPort: message['sendPort'] as SendPort,
      errorPort: onError,
      exitPort: onExit,
      rpcReceive: rpcReceive,
      includeDiscoveryMetadata: includeDiscoveryMetadata,
      acknowledgeKill: acknowledgeKills,
      onKill: () {
        killCount += 1;
        liveChildren -= 1;
      },
    );
    children.add(child);
    rpcReceive.listen((message) {
      if (message is! Map) return;
      final request = Map<String, dynamic>.from(message);
      rpcRequests.add(request);
      if (respondToTrustedPeers &&
          request['method'] == 'rift.listTrustedPeers') {
        child.uiPort.send({
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {'peers': <Object>[]},
        });
      }
    });
    if (!spawned.isCompleted) {
      spawned.complete();
    }

    final outcome = _outcomes.removeAt(0);
    switch (outcome) {
      case _StartupOutcome.ready:
        child.sendReady();
      case _StartupOutcome.error:
        child.sendError();
      case _StartupOutcome.exit:
        child.sendExit();
      case _StartupOutcome.pending:
        break;
    }
    return Future<void Function()>.value(child.kill);
  }

  Future<void> dispose() async {
    for (final child in children) {
      child.close();
    }
    for (final port in _tlsPorts) {
      port.close();
    }
    await rpcRequests.close();
  }
}

class _FakeChild {
  _FakeChild({
    required this.uiPort,
    required this.errorPort,
    required this.exitPort,
    required this.rpcReceive,
    required this.includeDiscoveryMetadata,
    required this.acknowledgeKill,
    required this.onKill,
  });

  final SendPort uiPort;
  final SendPort errorPort;
  final SendPort exitPort;
  final ReceivePort rpcReceive;
  final bool includeDiscoveryMetadata;
  final bool acknowledgeKill;
  final void Function() onKill;
  bool _alive = true;

  void sendReady() {
    uiPort.send({
      'jsonrpc': '2.0',
      'method': 'rift.daemonReady',
      'params': {
        'rpcPort': rpcReceive.sendPort,
        if (includeDiscoveryMetadata) ...{
          'deviceId': 'test-device',
          'advertisedPort': 11112,
          'fingerprintPrefix': 'abcdef',
        },
      },
    });
  }

  void sendError() {
    errorPort.send(<Object>['test isolate error', 'test stack']);
  }

  void sendExit() {
    exitPort.send(null);
  }

  void kill() {
    if (!_alive) return;
    _alive = false;
    onKill();
    if (acknowledgeKill) {
      scheduleMicrotask(acknowledgeExit);
    }
  }

  void acknowledgeExit() {
    exitPort.send(null);
  }

  void close() {
    rpcReceive.close();
  }
}

class _FakeDiscoveryBridge implements AndroidDiscoveryBridge {
  _FakeDiscoveryBridge() {
    _added = _subscriptionController();
    _lost = _subscriptionController();
    _retry = _subscriptionController();
  }

  late final StreamController<AndroidDiscoveredPeer> _added;
  late final StreamController<AndroidDiscoveredPeer> _lost;
  late final StreamController<AndroidDiscoveredPeer> _retry;
  final Completer<void> allSubscriptionsAttached = Completer<void>();
  int activeSubscriptions = 0;
  int cancelledSubscriptions = 0;
  int disposeCalls = 0;
  bool _isDiscovering = false;

  StreamController<AndroidDiscoveredPeer> _subscriptionController() {
    return StreamController<AndroidDiscoveredPeer>.broadcast(
      onListen: () {
        activeSubscriptions += 1;
        if (activeSubscriptions == 3 && !allSubscriptionsAttached.isCompleted) {
          allSubscriptionsAttached.complete();
        }
      },
      onCancel: () {
        activeSubscriptions -= 1;
        cancelledSubscriptions += 1;
      },
    );
  }

  @override
  Stream<AndroidDiscoveredPeer> get onPeerDiscovered => _added.stream;

  @override
  Stream<AndroidDiscoveredPeer> get onPeerLost => _lost.stream;

  @override
  Stream<AndroidDiscoveredPeer> get onReverseTcpPingRequested => _retry.stream;

  @override
  bool get isDiscovering => _isDiscovering;

  @override
  List<Map<String, dynamic>> listPeersForDaemonControl() => const [];

  @override
  List<Map<String, dynamic>> listPeersForIpc() => const [];

  @override
  Future<void> ensureAdvertising() async {}

  @override
  Future<void> startDiscovery() async {
    _isDiscovering = true;
  }

  @override
  Future<void> stopDiscovery() async {
    _isDiscovering = false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    await _added.close();
    await _lost.close();
    await _retry.close();
  }
}
