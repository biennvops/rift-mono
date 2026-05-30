abstract class TrustStore {
  Future<void> initialize();
  Future<void> saveTrustedDevice(String deviceId, String fingerprint);
  Future<bool> isDeviceTrusted(String deviceId);
  Future<void> revokeDevice(String deviceId);
}
