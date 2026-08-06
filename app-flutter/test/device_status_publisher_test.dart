import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/device_status/device_status_publisher.dart';

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
  });
}
