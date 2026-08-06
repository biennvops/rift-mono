import 'dart:io';

import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/device_status/device_status_manager.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';

void main() {
  test('DeviceStatusManager uses monotonic elapsed time for freshness', () {
    var monotonicNow = Duration.zero;
    final manager = DeviceStatusManager(monotonicNow: () => monotonicNow);
    manager.update(
      const DeviceStatusRecord(
        sourceDeviceId: 'rift-peer',
        batteryPresent: true,
        batteryPercent: 64,
        chargingState: 'charging',
        observedAt: '2026-07-16T10:00:00.000Z',
      ),
    );

    monotonicNow = const Duration(minutes: 29);
    expect(manager.getStatus('rift-peer')!.isStale, isFalse);
    monotonicNow = const Duration(minutes: 30);
    expect(manager.getStatus('rift-peer')!.isStale, isTrue);
    expect(manager.getStatus('rift-peer', isOnline: false)!.isStale, isTrue);
    manager.dispose();
  });

  group('RiftDaemon device status', () {
    late Directory tempDir;
    late RiftDaemon daemon;
    late List<Map<String, dynamic>> ipcEvents;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rift_device_status');
      ipcEvents = <Map<String, dynamic>>[];
      daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
        onIpcEvent: ipcEvents.add,
      );
      await daemon.start();
    });

    tearDown(() async {
      await daemon.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('stores and reports local power state', () async {
      final result = await daemon.handleJsonRpcRequest({
        'method': 'rift.notifyLocalDeviceStatus',
        'params': {
          'batteryPresent': true,
          'batteryPercent': 64,
          'chargingState': 'charging',
          'powerSource': 'usb',
          'lowPowerMode': false,
          'sourcePlatform': 'android',
          'observedAt': '2026-07-16T10:00:00.000Z',
        },
      });

      expect(result['broadcastTo'], isEmpty);
      expect(
        ipcEvents.any(
          (event) =>
              event['method'] == 'rift.onDeviceStatusUpdated' &&
              event['params']['batteryPresent'] == true &&
              event['params']['batteryPercent'] == 64,
        ),
        isTrue,
      );
    });

    test('rejects invalid battery percentage', () async {
      await expectLater(
        daemon.handleJsonRpcRequest({
          'method': 'rift.notifyLocalDeviceStatus',
          'params': {'batteryPercent': 101},
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('audits a spoofed peer status identity', () async {
      final context =
          SessionContext(peerDeviceId: 'rift-peer-spoof', isInitiator: false)
            ..handshakeState = HandshakeState.established
            ..trustState = TrustState.trusted
            ..capabilityNegotiated = true
            ..negotiatedCapabilities = [
              Capability(name: 'device.status', version: 1),
            ];
      daemon.sessionManagerForTesting.injectContextForTesting(context);

      await daemon.handleDeviceStatusProtocolMessageForTesting(
        'rift-peer-spoof',
        {
          'type': 'device.statusUpdated',
          'messageId': '018f2f9a-8b7c-4a4b-9c0d-bbbbbbbbbbbb',
          'sourceDeviceId': 'rift-peer-spoof',
          'payload': {
            'sourceDeviceId': 'rift-spoofed-status',
            'batteryPresent': true,
            'batteryPercent': 42,
            'observedAt': '2026-07-16T10:00:00.000Z',
          },
        },
      );

      final result = await daemon.handleJsonRpcRequest({
        'method': 'rift.queryEventLog',
        'params': {
          'eventTypes': ['auth.failed'],
          'peerDeviceId': 'rift-peer-spoof',
        },
      });
      final events = result['events'] as List<dynamic>;
      expect(events, hasLength(1));
      final event = Map<String, dynamic>.from(events.single as Map);
      expect(event['severity'], 'critical');
      expect(event['outcome'], 'denied');
      expect(event['failureReason'], 'Unauthorized');
      expect(event['details']['messageType'], 'device.statusUpdated');
      expect(event['details']['identityField'], 'sourceDeviceId');
    });

    test('accepts a negotiated peer status update', () async {
      final context =
          SessionContext(peerDeviceId: 'rift-peer-status', isInitiator: false)
            ..handshakeState = HandshakeState.established
            ..trustState = TrustState.trusted
            ..capabilityNegotiated = true
            ..negotiatedCapabilities = [
              Capability(name: 'device.status', version: 1),
            ];
      daemon.sessionManagerForTesting.injectContextForTesting(context);

      await daemon.handleDeviceStatusProtocolMessageForTesting(
        'rift-peer-status',
        {
          'type': 'device.statusUpdated',
          'messageId': '018f2f9a-8b7c-4a4b-9c0d-aaaaaaaaaaaa',
          'sourceDeviceId': 'rift-peer-status',
          'payload': {
            'sourceDeviceId': 'rift-peer-status',
            'batteryPresent': true,
            'batteryPercent': 42,
            'chargingState': 'discharging',
            'powerSource': 'battery',
            'lowPowerMode': true,
            'observedAt': '2026-07-16T10:00:00.000Z',
          },
        },
      );

      expect(ipcEvents.last['method'], 'rift.onDeviceStatusUpdated');
      expect(ipcEvents.last['params']['batteryPresent'], isTrue);
      expect(ipcEvents.last['params']['batteryPercent'], 42);
      expect(ipcEvents.last['params']['lowPowerMode'], isTrue);
    });
  });
}
