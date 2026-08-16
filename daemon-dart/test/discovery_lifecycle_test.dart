import 'dart:async';
import 'dart:io';

import 'package:daemon_dart/src/interfaces/discovery_service.dart';
import 'package:daemon_dart/src/network/discovery_service_impl.dart';
import 'package:daemon_dart/src/network/fallback_interface_snapshot.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:test/test.dart';

class _ManualPeriodicTimer implements DiscoveryPeriodicTimer {
  final Duration interval;
  final Future<void> Function() _callback;

  bool cancelled = false;
  int cancelCalls = 0;

  _ManualPeriodicTimer(this.interval, this._callback);

  Future<void> fire({bool evenIfCancelled = false}) {
    if (cancelled && !evenIfCancelled) return Future<void>.value();
    return _callback();
  }

  @override
  void cancel() {
    cancelCalls++;
    cancelled = true;
  }
}

class _ManualPeriodicScheduler {
  final timers = <_ManualPeriodicTimer>[];

  DiscoveryPeriodicTimer create(
    Duration interval,
    Future<void> Function() callback,
  ) {
    final timer = _ManualPeriodicTimer(interval, callback);
    timers.add(timer);
    return timer;
  }

  _ManualPeriodicTimer latest(Duration interval) =>
      timers.lastWhere((timer) => timer.interval == interval);

  int count(Duration interval) =>
      timers.where((timer) => timer.interval == interval).length;
}

class _FakeAdvertiserSocket implements DiscoveryAdvertiserSocket {
  bool closed = false;
  bool broadcastEnabledValue = false;
  int sendCalls = 0;

  @override
  set broadcastEnabled(bool enabled) => broadcastEnabledValue = enabled;

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (closed) throw StateError('Cannot send through a closed socket.');
    sendCalls++;
    return buffer.length;
  }

  @override
  void close() => closed = true;
}

class _FakeFallbackListener implements DiscoveryFallbackListener {
  final _datagrams = StreamController<Datagram>.broadcast(sync: true);

  bool closed = false;
  int closeCalls = 0;

  @override
  Stream<Datagram> get datagrams => _datagrams.stream;

  @override
  void close() {
    closeCalls++;
    if (closed) return;
    closed = true;
    unawaited(_datagrams.close());
  }
}

typedef _InterfaceStep = Future<List<FallbackInterfaceSnapshot>> Function();
typedef _RegistrationStep =
    Future<nsd.Registration> Function(nsd.Service service);
typedef _RegistrationStopStep =
    Future<void> Function(nsd.Registration registration);
typedef _DiscoveryStartStep = Future<nsd.Discovery> Function(String type);
typedef _DiscoveryStopStep = Future<void> Function(nsd.Discovery discovery);
typedef _SocketBindStep =
    Future<DiscoveryAdvertiserSocket> Function(InternetAddress address);

class _FakeDiscoveryDependencies {
  final scheduler = _ManualPeriodicScheduler();
  final interfaceSteps = <_InterfaceStep>[];
  final registrationSteps = <_RegistrationStep>[];
  final unregisterSteps = <_RegistrationStopStep>[];
  final discoveryStartSteps = <_DiscoveryStartStep>[];
  final discoveryStopSteps = <_DiscoveryStopStep>[];
  final socketBindSteps = <_SocketBindStep>[];

  int interfaceCalls = 0;
  int activeInterfaceCalls = 0;
  int maxActiveInterfaceCalls = 0;
  int registrationCalls = 0;
  int unregisterCalls = 0;
  int discoveryStartCalls = 0;
  int activeDiscoveryStartCalls = 0;
  int maxActiveDiscoveryStartCalls = 0;
  int discoveryStopCalls = 0;
  int activeDiscoveryStopCalls = 0;
  int maxActiveDiscoveryStopCalls = 0;
  int socketBindCalls = 0;
  int activeSocketBindCalls = 0;
  int maxActiveSocketBindCalls = 0;
  int fallbackListenerBindCalls = 0;

  final registrations = <nsd.Registration>[];
  final unregistered = <nsd.Registration>[];
  final discoveries = <nsd.Discovery>[];
  final stoppedDiscoveries = <nsd.Discovery>[];
  final sockets = <_FakeAdvertiserSocket>[];
  final listeners = <_FakeFallbackListener>[];

  Future<List<FallbackInterfaceSnapshot>> enumerateInterfaces() async {
    interfaceCalls++;
    activeInterfaceCalls++;
    if (activeInterfaceCalls > maxActiveInterfaceCalls) {
      maxActiveInterfaceCalls = activeInterfaceCalls;
    }
    try {
      if (interfaceSteps.isEmpty) return const [];
      return await interfaceSteps.removeAt(0)();
    } finally {
      activeInterfaceCalls--;
    }
  }

  Future<nsd.Registration> register(nsd.Service service) async {
    registrationCalls++;
    final registration = registrationSteps.isEmpty
        ? nsd.Registration('registration-$registrationCalls', service)
        : await registrationSteps.removeAt(0)(service);
    registrations.add(registration);
    return registration;
  }

  Future<void> unregister(nsd.Registration registration) async {
    unregisterCalls++;
    if (unregisterSteps.isNotEmpty) {
      await unregisterSteps.removeAt(0)(registration);
    }
    unregistered.add(registration);
  }

  Future<nsd.Discovery> startDiscovery(String type) async {
    discoveryStartCalls++;
    activeDiscoveryStartCalls++;
    if (activeDiscoveryStartCalls > maxActiveDiscoveryStartCalls) {
      maxActiveDiscoveryStartCalls = activeDiscoveryStartCalls;
    }
    try {
      final discovery = discoveryStartSteps.isEmpty
          ? nsd.Discovery('discovery-$discoveryStartCalls')
          : await discoveryStartSteps.removeAt(0)(type);
      discoveries.add(discovery);
      return discovery;
    } finally {
      activeDiscoveryStartCalls--;
    }
  }

  Future<void> stopDiscovery(nsd.Discovery discovery) async {
    discoveryStopCalls++;
    activeDiscoveryStopCalls++;
    if (activeDiscoveryStopCalls > maxActiveDiscoveryStopCalls) {
      maxActiveDiscoveryStopCalls = activeDiscoveryStopCalls;
    }
    try {
      if (discoveryStopSteps.isNotEmpty) {
        await discoveryStopSteps.removeAt(0)(discovery);
      }
      stoppedDiscoveries.add(discovery);
    } finally {
      activeDiscoveryStopCalls--;
    }
  }

  Future<DiscoveryAdvertiserSocket> bindAdvertiserSocket(
    InternetAddress address,
  ) async {
    socketBindCalls++;
    activeSocketBindCalls++;
    if (activeSocketBindCalls > maxActiveSocketBindCalls) {
      maxActiveSocketBindCalls = activeSocketBindCalls;
    }
    try {
      final socket = socketBindSteps.isEmpty
          ? _FakeAdvertiserSocket()
          : await socketBindSteps.removeAt(0)(address);
      if (socket is _FakeAdvertiserSocket) sockets.add(socket);
      return socket;
    } finally {
      activeSocketBindCalls--;
    }
  }

  Future<DiscoveryFallbackListener> bindFallbackListener() async {
    fallbackListenerBindCalls++;
    final listener = _FakeFallbackListener();
    listeners.add(listener);
    return listener;
  }

  DiscoveryServiceImpl createService() => DiscoveryServiceImpl(
    port: 9140,
    interfaceEnumerator: enumerateInterfaces,
    nsdRegister: register,
    nsdUnregister: unregister,
    nsdStart: startDiscovery,
    nsdStop: stopDiscovery,
    advertiserSocketBinder: bindAdvertiserSocket,
    fallbackListenerBinder: bindFallbackListener,
    periodicTimerFactory: scheduler.create,
  );
}

const _wifi = [
  FallbackInterfaceSnapshot(interfaceName: 'wifi', address: '192.168.1.10'),
];
const _hotspot = [
  FallbackInterfaceSnapshot(interfaceName: 'hotspot', address: '10.0.0.1'),
];

void main() {
  group('DiscoveryServiceImpl lifecycle', () {
    test('advertiser maintenance ticks do not overlap', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startAdvertising();

      final enumeration = Completer<List<FallbackInterfaceSnapshot>>();
      dependencies.interfaceSteps.add(() => enumeration.future);
      dependencies.interfaceSteps.add(() async => const []);
      final timer = dependencies.scheduler.latest(const Duration(seconds: 2));

      final firstTick = timer.fire();
      final secondTick = timer.fire();

      expect(dependencies.interfaceCalls, 2);
      expect(dependencies.activeInterfaceCalls, 1);
      expect(dependencies.maxActiveInterfaceCalls, 1);

      enumeration.complete(const []);
      await Future.wait([firstTick, secondTick]);
      await timer.fire();

      expect(dependencies.interfaceCalls, 3);
      expect(dependencies.maxActiveInterfaceCalls, 1);
    });

    test('interface enumeration is globally single-flight', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startAdvertising();
      await service.startDiscovery();

      final enumeration = Completer<List<FallbackInterfaceSnapshot>>();
      dependencies.interfaceSteps.add(() => enumeration.future);
      final advertiserTimer = dependencies.scheduler.latest(
        const Duration(seconds: 2),
      );
      final discoveryTimer = dependencies.scheduler.latest(
        const Duration(seconds: 30),
      );

      final advertiserRefresh = advertiserTimer.fire();
      final discoveryRefresh = discoveryTimer.fire();

      expect(dependencies.interfaceCalls, 2);
      expect(dependencies.activeInterfaceCalls, 1);

      enumeration.complete(_wifi);
      await Future.wait([advertiserRefresh, discoveryRefresh]);

      expect(dependencies.interfaceCalls, 2);
      expect(dependencies.maxActiveInterfaceCalls, 1);
      expect(dependencies.socketBindCalls, 2);
      expect(dependencies.discoveryStartCalls, 2);
      expect(dependencies.discoveryStopCalls, 1);
    });

    test('fallback socket rebinds cannot overlap', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startAdvertising();

      dependencies.interfaceSteps.add(() async => _wifi);
      final bindStarted = Completer<void>();
      final bindRelease = Completer<DiscoveryAdvertiserSocket>();
      dependencies.socketBindSteps.add((_) {
        bindStarted.complete();
        return bindRelease.future;
      });
      final timer = dependencies.scheduler.latest(const Duration(seconds: 2));

      final firstTick = timer.fire();
      await bindStarted.future;
      final secondTick = timer.fire();

      expect(dependencies.socketBindCalls, 2);
      expect(dependencies.activeSocketBindCalls, 1);
      expect(dependencies.maxActiveSocketBindCalls, 1);

      bindRelease.complete(_FakeAdvertiserSocket());
      await Future.wait([firstTick, secondTick]);

      expect(dependencies.socketBindCalls, 2);
      expect(dependencies.maxActiveSocketBindCalls, 1);
    });

    test('stopAdvertising prevents a stale rebind', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startAdvertising();
      final originalSocket = dependencies.sockets.single;

      final enumeration = Completer<List<FallbackInterfaceSnapshot>>();
      dependencies.interfaceSteps.add(() => enumeration.future);
      final timer = dependencies.scheduler.latest(const Duration(seconds: 2));

      final tick = timer.fire();
      expect(dependencies.interfaceCalls, 2);
      final stopping = service.stopAdvertising();
      enumeration.complete(_wifi);
      await Future.wait([tick, stopping]);

      expect(dependencies.socketBindCalls, 1);
      expect(originalSocket.closed, isTrue);
      expect(dependencies.unregisterCalls, 1);
    });

    test(
      'stopAdvertising propagates unregister failure and permits retry',
      () async {
        final dependencies = _FakeDiscoveryDependencies();
        final service = dependencies.createService();
        addTearDown(service.dispose);
        await service.startAdvertising();
        final registration = dependencies.registrations.single;
        final failure = StateError('simulated unregister failure');
        dependencies.unregisterSteps.add((_) => Future<void>.error(failure));

        final stopping = service.stopAdvertising();
        final restarting = service.startAdvertising();
        await Future.wait([
          expectLater(stopping, throwsA(same(failure))),
          expectLater(restarting, throwsA(same(failure))),
        ]);

        expect(dependencies.unregisterCalls, 1);
        expect(dependencies.unregistered, isEmpty);
        expect(service.startAdvertising, throwsStateError);
        expect(dependencies.registrationCalls, 1);

        await service.stopAdvertising();

        expect(dependencies.unregisterCalls, 2);
        expect(dependencies.unregistered, [registration]);

        await service.startAdvertising();
        expect(dependencies.registrationCalls, 2);
      },
    );

    test(
      'stopAdvertising retains a late registration after cleanup fails',
      () async {
        final dependencies = _FakeDiscoveryDependencies();
        final registerCalled = Completer<void>();
        final registerRelease = Completer<nsd.Registration>();
        late nsd.Service registeredService;
        dependencies.registrationSteps.add((service) {
          registeredService = service;
          registerCalled.complete();
          return registerRelease.future;
        });
        final service = dependencies.createService();
        addTearDown(service.dispose);

        final starting = service.startAdvertising();
        await registerCalled.future;
        final staleFailure = StateError('simulated stale unregister failure');
        final stopFailure = StateError('simulated unregister retry failure');
        dependencies.unregisterSteps
          ..add((_) => Future<void>.error(staleFailure))
          ..add((_) => Future<void>.error(stopFailure));
        final stopping = service.stopAdvertising();
        final stopExpectation = expectLater(
          stopping,
          throwsA(same(stopFailure)),
        );
        final registration = nsd.Registration(
          'late-registration',
          registeredService,
        );
        registerRelease.complete(registration);

        await Future.wait([starting, stopExpectation]);

        expect(dependencies.unregisterCalls, 2);
        expect(dependencies.unregistered, isEmpty);
        expect(service.startAdvertising, throwsStateError);

        await service.stopAdvertising();

        expect(dependencies.unregisterCalls, 3);
        expect(dependencies.unregistered, [registration]);
      },
    );

    test('stopAdvertising closes a socket from a stale bind', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startAdvertising();
      final originalSocket = dependencies.sockets.single;

      dependencies.interfaceSteps.add(() async => _wifi);
      final bindStarted = Completer<void>();
      final bindRelease = Completer<DiscoveryAdvertiserSocket>();
      dependencies.socketBindSteps.add((_) {
        bindStarted.complete();
        return bindRelease.future;
      });
      final timer = dependencies.scheduler.latest(const Duration(seconds: 2));

      final tick = timer.fire();
      await bindStarted.future;
      final stopping = service.stopAdvertising();
      final staleSocket = _FakeAdvertiserSocket();
      bindRelease.complete(staleSocket);
      await Future.wait([tick, stopping]);

      expect(originalSocket.closed, isTrue);
      expect(staleSocket.closed, isTrue);
      expect(staleSocket.sendCalls, 0);
    });

    test('a stale advertiser tick cannot send after stop', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startAdvertising();
      final originalSocket = dependencies.sockets.single;

      final enumeration = Completer<List<FallbackInterfaceSnapshot>>();
      dependencies.interfaceSteps.add(() => enumeration.future);
      final timer = dependencies.scheduler.latest(const Duration(seconds: 2));

      final tick = timer.fire();
      final stopping = service.stopAdvertising();
      enumeration.complete(const []);
      await Future.wait([tick, stopping]);

      expect(originalSocket.sendCalls, 0);
      expect(originalSocket.closed, isTrue);
    });

    test('discovery refreshes do not overlap', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startDiscovery();

      dependencies.interfaceSteps.add(() async => _wifi);
      final stopStarted = Completer<void>();
      final stopRelease = Completer<void>();
      dependencies.discoveryStopSteps.add((_) {
        stopStarted.complete();
        return stopRelease.future;
      });
      final timer = dependencies.scheduler.latest(const Duration(seconds: 30));

      final firstRefresh = timer.fire();
      await stopStarted.future;
      final secondRefresh = timer.fire();

      expect(dependencies.discoveryStopCalls, 1);
      expect(dependencies.activeDiscoveryStopCalls, 1);
      expect(dependencies.discoveryStartCalls, 1);

      stopRelease.complete();
      await Future.wait([firstRefresh, secondRefresh]);

      expect(dependencies.discoveryStopCalls, 1);
      expect(dependencies.discoveryStartCalls, 2);
      expect(dependencies.maxActiveDiscoveryStopCalls, 1);
      expect(dependencies.maxActiveDiscoveryStartCalls, 1);
    });

    test('failed discovery refresh stop does not start a duplicate', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startDiscovery();
      final originalDiscovery = dependencies.discoveries.single;
      dependencies.interfaceSteps.add(() async => _wifi);
      dependencies.discoveryStopSteps.add(
        (_) => Future<void>.error(StateError('simulated refresh stop failure')),
      );
      final timer = dependencies.scheduler.latest(const Duration(seconds: 30));

      await timer.fire();

      expect(dependencies.discoveryStopCalls, 1);
      expect(dependencies.discoveryStartCalls, 1);
      expect(dependencies.stoppedDiscoveries, isEmpty);

      dependencies.interfaceSteps.add(() async => _hotspot);
      await timer.fire();

      expect(dependencies.discoveryStopCalls, 2);
      expect(dependencies.discoveryStartCalls, 2);
      expect(dependencies.stoppedDiscoveries, [originalDiscovery]);
    });

    test('stopDiscovery disposes a stale NSD start', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startDiscovery();
      final originalDiscovery = dependencies.discoveries.single;

      dependencies.interfaceSteps.add(() async => _wifi);
      final startCalled = Completer<void>();
      final startRelease = Completer<nsd.Discovery>();
      dependencies.discoveryStartSteps.add((_) {
        startCalled.complete();
        return startRelease.future;
      });
      final timer = dependencies.scheduler.latest(const Duration(seconds: 30));

      final refresh = timer.fire();
      await startCalled.future;
      final stopping = service.stopDiscovery();
      final staleDiscovery = nsd.Discovery('stale');
      startRelease.complete(staleDiscovery);
      await Future.wait([refresh, stopping]);

      expect(
        dependencies.stoppedDiscoveries,
        containsAll([originalDiscovery, staleDiscovery]),
      );
      expect(dependencies.discoveryStartCalls, 2);
    });

    test('stopDiscovery propagates stop failure and permits retry', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startDiscovery();
      final discovery = dependencies.discoveries.single;
      final failure = StateError('simulated discovery stop failure');
      dependencies.discoveryStopSteps.add((_) => Future<void>.error(failure));

      final stopping = service.stopDiscovery();
      final restarting = service.startDiscovery();
      await Future.wait([
        expectLater(stopping, throwsA(same(failure))),
        expectLater(restarting, throwsA(same(failure))),
      ]);

      expect(dependencies.discoveryStopCalls, 1);
      expect(dependencies.stoppedDiscoveries, isEmpty);
      expect(service.startDiscovery, throwsStateError);
      expect(dependencies.discoveryStartCalls, 1);

      await service.stopDiscovery();

      expect(dependencies.discoveryStopCalls, 2);
      expect(dependencies.stoppedDiscoveries, [discovery]);

      await service.startDiscovery();
      expect(dependencies.discoveryStartCalls, 2);
    });

    test(
      'stopDiscovery retains a late discovery after cleanup fails',
      () async {
        final dependencies = _FakeDiscoveryDependencies();
        final startCalled = Completer<void>();
        final startRelease = Completer<nsd.Discovery>();
        dependencies.discoveryStartSteps.add((_) {
          startCalled.complete();
          return startRelease.future;
        });
        final service = dependencies.createService();
        addTearDown(service.dispose);

        final starting = service.startDiscovery();
        await startCalled.future;
        final staleFailure = StateError(
          'simulated stale discovery stop failure',
        );
        final stopFailure = StateError(
          'simulated discovery stop retry failure',
        );
        dependencies.discoveryStopSteps
          ..add((_) => Future<void>.error(staleFailure))
          ..add((_) => Future<void>.error(stopFailure));
        final stopping = service.stopDiscovery();
        final stopExpectation = expectLater(
          stopping,
          throwsA(same(stopFailure)),
        );
        final discovery = nsd.Discovery('late-discovery');
        startRelease.complete(discovery);

        await Future.wait([starting, stopExpectation]);

        expect(dependencies.discoveryStopCalls, 2);
        expect(dependencies.stoppedDiscoveries, isEmpty);
        expect(service.startDiscovery, throwsStateError);

        await service.stopDiscovery();

        expect(dependencies.discoveryStopCalls, 3);
        expect(dependencies.stoppedDiscoveries, [discovery]);
      },
    );

    test('a stale NSD callback cannot read a replacement discovery', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final originalDiscovery = nsd.Discovery('original');
      final replacementDiscovery = nsd.Discovery('replacement')
        ..add(
          const nsd.Service(
            name: 'replacement-peer',
            type: '_rift._tcp',
            host: '192.168.1.20',
            port: 9140,
          ),
        );
      dependencies.discoveryStartSteps.add((_) async => originalDiscovery);
      dependencies.discoveryStartSteps.add((_) async => replacementDiscovery);
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startDiscovery();

      dependencies.interfaceSteps.add(() async => _wifi);
      await dependencies.scheduler.latest(const Duration(seconds: 30)).fire();

      final events = <DiscoveredPeer>[];
      final subscription = service.onDeviceDiscovered.listen(events.add);
      addTearDown(subscription.cancel);
      originalDiscovery.add(
        const nsd.Service(
          name: 'stale-peer',
          type: '_rift._tcp',
          host: '192.168.1.30',
          port: 9140,
        ),
      );
      final microtaskBarrier = Completer<void>();
      scheduleMicrotask(microtaskBarrier.complete);
      await microtaskBarrier.future;

      expect(events, isEmpty);

      final validEvent = service.onDeviceDiscovered.first;
      replacementDiscovery.add(
        const nsd.Service(
          name: 'new-peer',
          type: '_rift._tcp',
          host: '192.168.1.40',
          port: 9140,
        ),
      );
      expect((await validEvent).instanceId, 'replacement-peer');
    });

    test('concurrent startDiscovery calls create one lifecycle', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final startCalled = Completer<void>();
      final startRelease = Completer<nsd.Discovery>();
      dependencies.discoveryStartSteps.add((_) {
        startCalled.complete();
        return startRelease.future;
      });
      final service = dependencies.createService();
      addTearDown(service.dispose);

      final firstStart = service.startDiscovery();
      final secondStart = service.startDiscovery();
      await startCalled.future;

      expect(dependencies.discoveryStartCalls, 1);
      startRelease.complete(nsd.Discovery('only-discovery'));
      await Future.wait([firstStart, secondStart]);

      expect(dependencies.discoveryStartCalls, 1);
      expect(dependencies.fallbackListenerBindCalls, 1);
      expect(dependencies.scheduler.count(const Duration(seconds: 30)), 1);
      expect(dependencies.scheduler.count(const Duration(seconds: 5)), 1);
    });

    test('concurrent startAdvertising calls create one lifecycle', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final registerCalled = Completer<void>();
      final registerRelease = Completer<nsd.Registration>();
      late nsd.Service registeredService;
      dependencies.registrationSteps.add((service) {
        registeredService = service;
        registerCalled.complete();
        return registerRelease.future;
      });
      final service = dependencies.createService();
      addTearDown(service.dispose);

      final firstStart = service.startAdvertising();
      final secondStart = service.startAdvertising();
      await registerCalled.future;

      expect(dependencies.registrationCalls, 1);
      registerRelease.complete(
        nsd.Registration('only-registration', registeredService),
      );
      await Future.wait([firstStart, secondStart]);

      expect(dependencies.registrationCalls, 1);
      expect(dependencies.interfaceCalls, 1);
      expect(dependencies.socketBindCalls, 1);
      expect(dependencies.scheduler.count(const Duration(seconds: 2)), 1);
    });

    test('stop/start generations cannot replace the new discovery', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      addTearDown(service.dispose);
      await service.startDiscovery();

      dependencies.interfaceSteps.add(() async => _hotspot);
      final staleStartCalled = Completer<void>();
      final staleStartRelease = Completer<nsd.Discovery>();
      dependencies.discoveryStartSteps.add((_) {
        staleStartCalled.complete();
        return staleStartRelease.future;
      });
      final refresh = dependencies.scheduler
          .latest(const Duration(seconds: 30))
          .fire();
      await staleStartCalled.future;

      final stopping = service.stopDiscovery();
      final restarting = service.startDiscovery();
      final staleDiscovery = nsd.Discovery('stale-generation');
      staleStartRelease.complete(staleDiscovery);
      await Future.wait([refresh, stopping, restarting]);

      final replacement = dependencies.discoveries.last;
      expect(dependencies.discoveryStartCalls, 3);
      expect(dependencies.stoppedDiscoveries, contains(staleDiscovery));
      expect(dependencies.stoppedDiscoveries, isNot(contains(replacement)));
    });

    test('dispose leaves no scheduled work and is terminal', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      await service.startAdvertising();
      await service.startDiscovery();
      final oldTimers = List<_ManualPeriodicTimer>.of(
        dependencies.scheduler.timers,
      );
      final interfaceCalls = dependencies.interfaceCalls;
      final socketBindCalls = dependencies.socketBindCalls;
      final discoveryStartCalls = dependencies.discoveryStartCalls;
      final sendCalls = dependencies.sockets.fold<int>(
        0,
        (total, socket) => total + socket.sendCalls,
      );

      await service.dispose();
      await Future.wait(
        oldTimers.map((timer) => timer.fire(evenIfCancelled: true)),
      );

      expect(dependencies.interfaceCalls, interfaceCalls);
      expect(dependencies.socketBindCalls, socketBindCalls);
      expect(dependencies.discoveryStartCalls, discoveryStartCalls);
      expect(
        dependencies.sockets.fold<int>(
          0,
          (total, socket) => total + socket.sendCalls,
        ),
        sendCalls,
      );
      expect(oldTimers.every((timer) => timer.cancelled), isTrue);
      expect(dependencies.sockets.every((socket) => socket.closed), isTrue);
      expect(
        dependencies.listeners.every((listener) => listener.closed),
        isTrue,
      );
      expect(service.startAdvertising, throwsStateError);
      expect(service.startDiscovery, throwsStateError);
    });

    test(
      'dispose retries retained teardown after first failure and completes disposal',
      () async {
        final dependencies = _FakeDiscoveryDependencies();
        final service = dependencies.createService();
        await service.startAdvertising();
        final registration = dependencies.registrations.single;
        final discoveredDone = service.onDeviceDiscovered.drain<void>();
        final lostDone = service.onDeviceLost.drain<void>();
        final failure = StateError('simulated unregister failure');
        dependencies.unregisterSteps.add((_) => Future<void>.error(failure));

        final firstDispose = service.dispose();
        final concurrentDispose = service.dispose();

        expect(identical(firstDispose, concurrentDispose), isTrue);
        await expectLater(firstDispose, throwsA(same(failure)));
        expect(dependencies.unregisterCalls, 1);
        expect(dependencies.unregistered, isEmpty);

        final retryDispose = service.dispose();

        expect(identical(firstDispose, retryDispose), isFalse);
        await retryDispose;
        await Future.wait([discoveredDone, lostDone]);
        expect(dependencies.unregisterCalls, 2);
        expect(dependencies.unregistered, [registration]);

        final completedDispose = service.dispose();

        expect(identical(retryDispose, completedDispose), isTrue);
        await completedDispose;
        expect(dependencies.unregisterCalls, 2);
      },
    );

    test('dispose is idempotent', () async {
      final dependencies = _FakeDiscoveryDependencies();
      final service = dependencies.createService();
      await service.startAdvertising();
      await service.startDiscovery();

      final firstDispose = service.dispose();
      final secondDispose = service.dispose();

      expect(identical(firstDispose, secondDispose), isTrue);
      await Future.wait([firstDispose, secondDispose]);
      expect(dependencies.unregisterCalls, 1);
      expect(dependencies.discoveryStopCalls, 1);
      expect(dependencies.listeners.single.closeCalls, 1);
      expect(dependencies.sockets.every((socket) => socket.closed), isTrue);
    });
  });
}
