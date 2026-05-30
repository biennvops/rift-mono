class DiscoveredPeer {
  final String deviceId;
  final String address;
  final int port;
  final String protocolVersion;

  DiscoveredPeer({
    required this.deviceId,
    required this.address,
    required this.port,
    required this.protocolVersion,
  });
}

abstract class DiscoveryService {
  Future<void> startAdvertising();
  Future<void> stopAdvertising();
  Stream<DiscoveredPeer> get onDeviceDiscovered;
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
}
