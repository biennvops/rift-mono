import 'dart:io';

class FallbackInterfaceSnapshot {
  final String interfaceName;
  final String address;

  const FallbackInterfaceSnapshot({
    required this.interfaceName,
    required this.address,
  });
}

class FallbackInterfaceSnapshotEnumerator {
  static Future<List<FallbackInterfaceSnapshot>> enumerateIPv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );

    final snapshots = <FallbackInterfaceSnapshot>[];
    final seen = <String>{};
    for (final interface in interfaces) {
      if (_isExcludedInterface(interface.name)) {
        continue;
      }

      for (final candidate in interface.addresses) {
        if (!_isEligibleAddress(candidate)) {
          continue;
        }

        final key = '${interface.name}|${candidate.address}';
        if (!seen.add(key)) {
          continue;
        }

        snapshots.add(
          FallbackInterfaceSnapshot(
            interfaceName: interface.name,
            address: candidate.address,
          ),
        );
      }
    }

    return snapshots;
  }

  static bool isEligibleAddressForTesting(InternetAddress address) =>
      _isEligibleAddress(address);

  static bool isExcludedInterfaceNameForTesting(String interfaceName) =>
      _isExcludedInterface(interfaceName);

  static bool _isEligibleAddress(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) {
      return false;
    }

    if (address.isLoopback) {
      return false;
    }

    final raw = address.rawAddress;
    if (raw.length != 4) {
      return false;
    }

    if (raw[0] == 169 && raw[1] == 254) {
      return false;
    }

    return true;
  }

  static bool _isExcludedInterface(String interfaceName) {
    final normalized = interfaceName.toLowerCase();
    return normalized.contains('loopback') ||
        normalized.startsWith('lo') ||
        normalized.contains('tun') ||
        normalized.contains('tap') ||
        normalized.contains('vpn') ||
        normalized.contains('utun') ||
        normalized.contains('bridge') ||
        normalized.contains('docker') ||
        normalized.contains('veth');
  }
}
