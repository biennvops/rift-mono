abstract class DiscoveryService {
  Future<void> startAdvertising();
  Future<void> stopAdvertising();
  Stream<dynamic> get onDeviceDiscovered;
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
}
