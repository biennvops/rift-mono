import 'dart:io';

import 'package:daemon_dart/src/network/fallback_interface_snapshot.dart';
import 'package:test/test.dart';

void main() {
  group('FallbackInterfaceSnapshotEnumerator', () {
    test('rejects APIPA addresses', () {
      final allowed = FallbackInterfaceSnapshotEnumerator
          .isEligibleAddressForTesting(InternetAddress('169.254.10.10'));

      expect(allowed, isFalse);
    });

    test('accepts RFC1918 IPv4 addresses', () {
      final allowed = FallbackInterfaceSnapshotEnumerator
          .isEligibleAddressForTesting(InternetAddress('192.168.10.10'));

      expect(allowed, isTrue);
    });

    test('filters common virtual and tunnel interface names', () {
      expect(
        FallbackInterfaceSnapshotEnumerator.isExcludedInterfaceNameForTesting(
          'tun0',
        ),
        isTrue,
      );
      expect(
        FallbackInterfaceSnapshotEnumerator.isExcludedInterfaceNameForTesting(
          'wlan0',
        ),
        isFalse,
      );
    });
  });
}
