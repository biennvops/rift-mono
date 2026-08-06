import 'dart:async';

class DeviceStatusRecord {
  final String sourceDeviceId;
  final String? sourcePlatform;
  final int? batteryPercent;
  final String? chargingState;
  final String? powerSource;
  final bool? lowPowerMode;
  final String observedAt;
  final bool isStale;

  const DeviceStatusRecord({
    required this.sourceDeviceId,
    this.sourcePlatform,
    this.batteryPercent,
    this.chargingState,
    this.powerSource,
    this.lowPowerMode,
    required this.observedAt,
    this.isStale = false,
  });

  Map<String, dynamic> toJson() => {
    'sourceDeviceId': sourceDeviceId,
    if (sourcePlatform != null) 'sourcePlatform': sourcePlatform,
    if (batteryPercent != null) 'batteryPercent': batteryPercent,
    if (chargingState != null) 'chargingState': chargingState,
    if (powerSource != null) 'powerSource': powerSource,
    if (lowPowerMode != null) 'lowPowerMode': lowPowerMode,
    'observedAt': observedAt,
    if (isStale) 'isStale': true,
  };

  DeviceStatusRecord withStale(bool value) => DeviceStatusRecord(
    sourceDeviceId: sourceDeviceId,
    sourcePlatform: sourcePlatform,
    batteryPercent: batteryPercent,
    chargingState: chargingState,
    powerSource: powerSource,
    lowPowerMode: lowPowerMode,
    observedAt: observedAt,
    isStale: value,
  );
}

class DeviceStatusManager {
  static const staleAfter = Duration(minutes: 30);

  final Map<String, _CachedDeviceStatus> _statuses = {};
  final _updatedController = StreamController<DeviceStatusRecord>.broadcast();

  Stream<DeviceStatusRecord> get onUpdated => _updatedController.stream;

  void update(DeviceStatusRecord status) {
    _statuses[status.sourceDeviceId] = _CachedDeviceStatus(
      status.withStale(false),
      DateTime.now(),
    );
    _updatedController.add(status.withStale(false));
  }

  DeviceStatusRecord? getStatus(String sourceDeviceId, {bool isOnline = true}) {
    final cached = _statuses[sourceDeviceId];
    if (cached == null) {
      return null;
    }
    final stale =
        !isOnline || DateTime.now().difference(cached.receivedAt) >= staleAfter;
    return cached.status.withStale(stale);
  }

  void dispose() {
    _updatedController.close();
  }
}

class _CachedDeviceStatus {
  final DeviceStatusRecord status;
  final DateTime receivedAt;

  const _CachedDeviceStatus(this.status, this.receivedAt);
}
