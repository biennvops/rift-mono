class DiscoveredPeer {
  final String instanceId;
  final String address;
  final int port;
  final String minVersion;
  final String maxVersion;
  final String? deviceIdHint;
  final String? fingerprintPrefix;

  DiscoveredPeer({
    required this.instanceId,
    required this.address,
    required this.port,
    required this.minVersion,
    required this.maxVersion,
    this.deviceIdHint,
    this.fingerprintPrefix,
  });
}

abstract class DiscoveryService {
  Future<void> startAdvertising();
  Future<void> stopAdvertising();
  Stream<DiscoveredPeer> get onDeviceDiscovered;
  Stream<String> get onDeviceLost;
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  /// Stops all discovery/advertising and closes internal stream controllers.
  Future<void> dispose();
}
