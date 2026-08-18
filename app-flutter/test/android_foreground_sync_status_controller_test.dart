import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/device_status/android_foreground_sync_status_controller.dart';

void main() {
  group('calculateAndroidForegroundSyncStatus', () {
    test('counts trusted peers and ignores non-trusted or offline peers', () {
      final status = calculateAndroidForegroundSyncStatus({
        'peers': [
          {
            'deviceId': 'trusted-offline',
            'trustState': 'trusted',
            'presence': 'offline',
          },
          {
            'deviceId': 'trusted-online',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': '  Work\n  Laptop\t  ',
          },
          {
            'deviceId': 'blocked',
            'trustState': 'blocked',
            'presence': 'online',
            'displayName': 'Blocked device',
          },
          {
            'deviceId': 'pending',
            'trustState': 'pairing_pending',
            'presence': 'online',
          },
        ],
      });

      expect(status.trustedPeerCount, 2);
      expect(status.connectedPeerCount, 1);
      expect(status.connectedPeerNames, ['Work Laptop']);
    });

    test('uses a safe fallback and bounds Unicode names', () {
      final longName = '😀' * 60;
      final status = calculateAndroidForegroundSyncStatus({
        'peers': [
          {
            'deviceId': 'missing-name',
            'trustState': 'trusted',
            'presence': 'online',
          },
          {
            'deviceId': 'long-name',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': longName,
          },
        ],
      });

      expect(status.connectedPeerNames.first, 'Trusted device');
      expect(status.connectedPeerNames.last.runes.length, 48);
      expect(status.connectedPeerNames.last, startsWith('😀'));
    });

    test('sorts names case-insensitively with device ID tie breaking', () {
      final status = calculateAndroidForegroundSyncStatus({
        'peers': [
          {
            'deviceId': 'z-device',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': 'alpha',
          },
          {
            'deviceId': 'a-device',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': 'Alpha',
          },
          {
            'deviceId': 'middle-device',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': 'Beta',
          },
        ],
      });

      expect(status.connectedPeerNames, ['Alpha', 'alpha', 'Beta']);
    });

    test('retains the real connected count when names are bounded', () {
      final peers = List<Map<String, dynamic>>.generate(
        8,
        (index) => {
          'deviceId': 'device-$index',
          'trustState': 'trusted',
          'presence': 'online',
          'displayName': 'Device $index',
        },
      );

      final status = calculateAndroidForegroundSyncStatus({'peers': peers});

      expect(status.trustedPeerCount, 8);
      expect(status.connectedPeerCount, 8);
      expect(status.connectedPeerNames, [
        'Device 0',
        'Device 1',
        'Device 2',
        'Device 3',
        'Device 4',
      ]);
    });
  });

  group('AndroidForegroundSyncStatusController', () {
    late StreamController<Map<String, dynamic>> trustChanged;
    late StreamController<Map<String, dynamic>> peerDiscovered;
    late StreamController<Map<String, dynamic>> peerLost;
    late StreamController<Map<String, dynamic>> deviceStatusUpdated;
    late StreamController<bool> connectionChanged;
    late List<AndroidForegroundSyncStatus> published;
    late Map<String, dynamic> response;
    late int listCalls;
    late AndroidForegroundSyncStatusController controller;

    setUp(() {
      trustChanged = StreamController<Map<String, dynamic>>.broadcast();
      peerDiscovered = StreamController<Map<String, dynamic>>.broadcast();
      peerLost = StreamController<Map<String, dynamic>>.broadcast();
      deviceStatusUpdated = StreamController<Map<String, dynamic>>.broadcast();
      connectionChanged = StreamController<bool>.broadcast();
      published = <AndroidForegroundSyncStatus>[];
      response = {'peers': <Map<String, dynamic>>[]};
      listCalls = 0;
      controller = AndroidForegroundSyncStatusController(
        listTrustedPeers: () async {
          listCalls++;
          return response;
        },
        publishForegroundSyncStatus: (status) async {
          published.add(status);
          return true;
        },
        onTrustChanged: trustChanged.stream,
        onPeerDiscovered: peerDiscovered.stream,
        onPeerLost: peerLost.stream,
        onDeviceStatusUpdated: deviceStatusUpdated.stream,
        onConnectionChanged: connectionChanged.stream,
        debounce: const Duration(milliseconds: 1),
        healingRefreshInterval: const Duration(hours: 1),
      );
    });

    tearDown(() async {
      await controller.dispose();
      await trustChanged.close();
      await peerDiscovered.close();
      await peerLost.close();
      await deviceStatusUpdated.close();
      await connectionChanged.close();
    });

    test('initial refresh publishes once and identical snapshots deduplicate',
        () async {
      await controller.start();
      expect(listCalls, 1);
      expect(published, hasLength(1));

      await controller.refreshNow();
      expect(listCalls, 2);
      expect(published, hasLength(1));
    });

    test('event bursts debounce into one refresh and publish changes',
        () async {
      await controller.start();
      response = {
        'peers': [
          {
            'deviceId': 'peer-1',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': 'MacBook Pro',
          },
        ],
      };

      trustChanged.add({});
      peerLost.add({});
      deviceStatusUpdated.add({});
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(listCalls, 2);
      expect(published, hasLength(2));
      expect(published.last.connectedPeerNames, ['MacBook Pro']);
    });

    test('coalesces requests while one list call is in flight', () async {
      final firstResponse = Completer<Map<String, dynamic>>();
      listCalls = 0;
      controller = AndroidForegroundSyncStatusController(
        listTrustedPeers: () {
          listCalls++;
          if (listCalls == 1) {
            return firstResponse.future;
          }
          return Future<Map<String, dynamic>>.value(response);
        },
        publishForegroundSyncStatus: (status) async {
          published.add(status);
          return true;
        },
        debounce: const Duration(milliseconds: 1),
        healingRefreshInterval: const Duration(hours: 1),
      );

      final start = controller.start();
      await Future<void>.delayed(Duration.zero);
      controller.requestRefresh();
      controller.requestRefresh();
      firstResponse.complete(response);
      await start;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(listCalls, 2);
    });

    test('publishes reconnecting and refreshes when connection returns',
        () async {
      await controller.start();
      connectionChanged.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(published.last.runtimeState,
          AndroidForegroundSyncRuntimeState.reconnecting);

      response = {
        'peers': [
          {
            'deviceId': 'peer-1',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': 'Phone',
          },
        ],
      };
      connectionChanged.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(
          published.last.runtimeState, AndroidForegroundSyncRuntimeState.ready);
      expect(published.last.connectedPeerNames, ['Phone']);
    });

    test('healing timer refreshes without waiting in real time', () {
      fakeAsync((async) {
        var calls = 0;
        final healingController = AndroidForegroundSyncStatusController(
          listTrustedPeers: () async {
            calls++;
            return response;
          },
          publishForegroundSyncStatus: (status) async => true,
          debounce: Duration.zero,
          healingRefreshInterval: const Duration(seconds: 60),
        );

        healingController.start();
        async.flushMicrotasks();
        expect(calls, 1);

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(calls, 2);

        healingController.dispose();
        async.flushMicrotasks();
      });
    });

    test('initial lookup failure does not claim zero trusted peers', () async {
      var fail = true;
      controller = AndroidForegroundSyncStatusController(
        listTrustedPeers: () async {
          if (fail) {
            throw StateError('daemon unavailable');
          }
          return response;
        },
        publishForegroundSyncStatus: (status) async {
          published.add(status);
          return true;
        },
        healingRefreshInterval: const Duration(hours: 1),
      );

      await controller.start();
      expect(published, isEmpty);

      fail = false;
      await controller.refreshNow();
      expect(published, hasLength(1));
      expect(
        published.single.runtimeState,
        AndroidForegroundSyncRuntimeState.ready,
      );
      expect(published.single.trustedPeerCount, 0);
    });

    test('lookup failure retains the last known peer snapshot', () async {
      var fail = false;
      response = {
        'peers': [
          {
            'deviceId': 'peer-1',
            'trustState': 'trusted',
            'presence': 'online',
            'displayName': 'MacBook Pro',
          },
        ],
      };
      controller = AndroidForegroundSyncStatusController(
        listTrustedPeers: () async {
          if (fail) {
            throw StateError('daemon unavailable');
          }
          return response;
        },
        publishForegroundSyncStatus: (status) async {
          published.add(status);
          return true;
        },
        healingRefreshInterval: const Duration(hours: 1),
      );
      await controller.start();
      expect(published, hasLength(1));
      expect(published.single.connectedPeerNames, ['MacBook Pro']);

      fail = true;
      await controller.refreshNow();
      expect(published, hasLength(1));
      expect(published.single.connectedPeerNames, ['MacBook Pro']);
    });

    test('dispose cancels pending work and prevents publication', () async {
      final responseGate = Completer<Map<String, dynamic>>();
      controller = AndroidForegroundSyncStatusController(
        listTrustedPeers: () => responseGate.future,
        publishForegroundSyncStatus: (status) async {
          published.add(status);
          return true;
        },
        healingRefreshInterval: const Duration(hours: 1),
      );

      final start = controller.start();
      final dispose = controller.dispose();
      responseGate.complete(response);
      await Future.wait<void>([start, dispose]);

      expect(published, isEmpty);
      expect(controller.isDisposed, isTrue);
    });
  });
}
