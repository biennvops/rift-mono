import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/device_status/device_status_publisher.dart';
import 'package:rift/src/ipc/ipc_transport.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:stream_channel/stream_channel.dart';

class _NoopTransport implements IpcTransport {
  @override
  Future<StreamChannel<String>> connect() => throw UnimplementedError();

  @override
  Future<void> disconnect() async {}
}

class _FakeDeviceStatusClient extends JsonRpcRiftClient {
  _FakeDeviceStatusClient() : super(_NoopTransport());

  final publications = <Map<String, Object?>>[];

  @override
  bool get isConnected => true;

  @override
  Future<dynamic> notifyLocalDeviceStatus({
    bool? batteryPresent,
    int? batteryPercent,
    String? chargingState,
    String? powerSource,
    bool? lowPowerMode,
    String? observedAt,
    String? sourcePlatform,
  }) async {
    publications.add({
      if (batteryPresent != null) 'batteryPresent': batteryPresent,
      if (batteryPercent != null) 'batteryPercent': batteryPercent,
      if (chargingState != null) 'chargingState': chargingState,
      if (powerSource != null) 'powerSource': powerSource,
      if (lowPowerMode != null) 'lowPowerMode': lowPowerMode,
      if (observedAt != null) 'observedAt': observedAt,
      if (sourcePlatform != null) 'sourcePlatform': sourcePlatform,
    });
    return null;
  }
}

Future<Directory> _createSupplyRoot(
  String name,
  Map<String, String> files,
) async {
  final root = await Directory.systemTemp.createTemp('rift-power-supply-');
  await _addSupply(root, name, files);
  return root;
}

Future<void> _addSupply(
  Directory root,
  String name,
  Map<String, String> files,
) async {
  final supply = Directory('${root.path}/$name')..createSync();
  for (final entry in files.entries) {
    await File('${supply.path}/${entry.key}').writeAsString(entry.value);
  }
}

void main() {
  group('DeviceStatusPublisher power parsing', () {
    test('Linux does not infer battery power from notCharging', () {
      expect(
        DeviceStatusPublisher.deriveLinuxPowerSource(
          chargingState: 'notCharging',
          externalPowerOnline: null,
        ),
        'unknown',
      );
      expect(
        DeviceStatusPublisher.deriveLinuxPowerSource(
          chargingState: 'notCharging',
          externalPowerOnline: true,
        ),
        'ac',
      );
    });

    test('Linux does not infer AC power from a full battery', () {
      expect(
        DeviceStatusPublisher.deriveLinuxPowerSource(
          chargingState: 'full',
          externalPowerOnline: null,
        ),
        'unknown',
      );
      expect(
        DeviceStatusPublisher.deriveLinuxPowerSource(
          chargingState: 'full',
          externalPowerOnline: true,
        ),
        'ac',
      );
    });

    test('Windows uses the charging bit instead of AC attachment', () {
      final pluggedIn = DeviceStatusPublisher.parseWindowsPowerStatus(
        acLineStatus: 1,
        batteryFlag: 0,
        batteryLifePercent: 80,
      );
      final charging = DeviceStatusPublisher.parseWindowsPowerStatus(
        acLineStatus: 1,
        batteryFlag: 0x08,
        batteryLifePercent: 80,
      );

      expect(pluggedIn['chargingState'], 'notCharging');
      expect(charging['chargingState'], 'charging');
    });

    test('Windows omits battery fields when no battery is installed', () {
      final status = DeviceStatusPublisher.parseWindowsPowerStatus(
        acLineStatus: 1,
        batteryFlag: 0x80,
        batteryLifePercent: 255,
      );

      expect(status['batteryPresent'], isFalse);
      expect(status.containsKey('batteryPercent'), isFalse);
      expect(status.containsKey('chargingState'), isFalse);
      expect(status['powerSource'], 'ac');
    });

    test('macOS recognizes AC attached without active charging', () {
      final status = DeviceStatusPublisher.parseMacOSPowerStatus(
        "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%; AC attached; not charging present: true",
      );

      expect(status['batteryPresent'], isTrue);
      expect(status['batteryPercent'], 80);
      expect(status['chargingState'], 'notCharging');
      expect(status['powerSource'], 'ac');
    });

    test('Linux detects a present battery by type rather than directory name',
        () async {
      if (!Platform.isLinux) {
        return;
      }
      final root = await _createSupplyRoot('PowerCell0', {
        'type': 'Battery',
        'present': '1',
        'capacity': '64',
        'status': 'Discharging',
      });
      try {
        await _addSupply(root, 'AC', {
          'type': 'Mains',
          'online': '0',
        });
        final client = _FakeDeviceStatusClient();
        final publisher = DeviceStatusPublisher(
          client,
          linuxPowerSupplyDirectory: root,
        );

        await publisher.publishCurrentStatus();

        expect(client.publications, hasLength(1));
        expect(client.publications.single['batteryPresent'], isTrue);
        expect(client.publications.single['batteryPercent'], 64);
        expect(client.publications.single['chargingState'], 'discharging');
        expect(client.publications.single['powerSource'], 'battery');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('Linux skips an absent battery supply and reports AC power', () async {
      if (!Platform.isLinux) {
        return;
      }
      final root = await _createSupplyRoot('BAT0', {
        'type': 'Battery',
        'present': '0',
        'capacity': '100',
        'status': 'Full',
      });
      try {
        await _addSupply(root, 'AC', {
          'type': 'Mains',
          'online': '1',
        });
        final client = _FakeDeviceStatusClient();
        final publisher = DeviceStatusPublisher(
          client,
          linuxPowerSupplyDirectory: root,
        );

        await publisher.publishCurrentStatus();

        expect(client.publications, hasLength(1));
        expect(client.publications.single['batteryPresent'], isFalse);
        expect(
            client.publications.single.containsKey('batteryPercent'), isFalse);
        expect(client.publications.single['powerSource'], 'ac');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('maximum-silence refresh uses monotonic elapsed time', () async {
      if (!Platform.isLinux) {
        return;
      }
      final root = await _createSupplyRoot('PowerCell0', {
        'type': 'Battery',
        'present': '1',
        'capacity': '64',
        'status': 'Discharging',
      });
      try {
        await _addSupply(root, 'AC', {
          'type': 'Mains',
          'online': '0',
        });
        var elapsed = Duration.zero;
        final client = _FakeDeviceStatusClient();
        final publisher = DeviceStatusPublisher(
          client,
          monotonicNow: () => elapsed,
          linuxPowerSupplyDirectory: root,
        );

        await publisher.publishCurrentStatus();
        elapsed = const Duration(minutes: 29);
        await publisher.publishCurrentStatus();
        expect(client.publications, hasLength(1));

        elapsed = const Duration(minutes: 30);
        await publisher.publishCurrentStatus();
        expect(client.publications, hasLength(2));
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}
