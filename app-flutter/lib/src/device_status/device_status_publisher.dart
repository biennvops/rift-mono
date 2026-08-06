import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ipc/json_rpc_client.dart';
import 'system_power_status.dart';

class DeviceStatusPublisher with WidgetsBindingObserver {
  DeviceStatusPublisher(this._client);

  static const _androidChannel = MethodChannel('rift/android/shell');
  static const _iosChannel = MethodChannel('rift/ios/device_status');
  static const _pollInterval = Duration(minutes: 5);
  static const _maximumSilence = Duration(minutes: 30);

  final JsonRpcRiftClient _client;
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _timer;
  Map<String, Object?>? _lastPublished;
  DateTime? _lastPublishedAt;
  bool _publishing = false;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _connectionSubscription = _client.onConnectionChanged.listen((connected) {
      if (connected) {
        unawaited(publishCurrentStatus());
      }
    });
    _timer = Timer.periodic(
      _pollInterval,
      (_) => unawaited(publishCurrentStatus()),
    );
    await publishCurrentStatus();
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    await _connectionSubscription?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(publishCurrentStatus());
    }
  }

  Future<void> publishCurrentStatus() async {
    if (_publishing || !_client.isConnected) {
      return;
    }
    _publishing = true;
    try {
      final status = await _readCurrentStatus();
      if (status == null || status.isEmpty || !_shouldPublish(status)) {
        return;
      }
      await _client.notifyLocalDeviceStatus(
        batteryPercent: status['batteryPercent'] as int?,
        chargingState: status['chargingState'] as String?,
        powerSource: status['powerSource'] as String?,
        lowPowerMode: status['lowPowerMode'] as bool?,
        sourcePlatform: status['sourcePlatform'] as String?,
        observedAt: DateTime.now().toUtc().toIso8601String(),
      );
      _lastPublished = Map<String, Object?>.from(status);
      _lastPublishedAt = DateTime.now();
    } catch (error) {
      debugPrint('[Device Status] Failed to publish local status: $error');
    } finally {
      _publishing = false;
    }
  }

  bool _shouldPublish(Map<String, Object?> status) {
    final previous = _lastPublished;
    if (previous == null) {
      return true;
    }
    if (previous['chargingState'] != status['chargingState'] ||
        previous['powerSource'] != status['powerSource'] ||
        previous['lowPowerMode'] != status['lowPowerMode']) {
      return true;
    }
    final previousBattery = previous['batteryPercent'] as int?;
    final battery = status['batteryPercent'] as int?;
    if (previousBattery == null || battery == null) {
      if (previousBattery != battery) {
        return true;
      }
    } else if ((previousBattery - battery).abs() >= 5) {
      return true;
    }
    final lastPublishedAt = _lastPublishedAt;
    return lastPublishedAt == null ||
        DateTime.now().difference(lastPublishedAt) >= _maximumSilence;
  }

  Future<Map<String, Object?>?> _readCurrentStatus() async {
    if (Platform.isAndroid) {
      final value = await _androidChannel.invokeMethod<Object?>(
        'getDeviceStatus',
      );
      return _normalizeNativeStatus(value);
    }
    if (Platform.isIOS) {
      final value = await _iosChannel.invokeMethod<Object?>(
        'getDeviceStatus',
      );
      return _normalizeNativeStatus(value);
    }
    if (Platform.isLinux) {
      return _readLinuxStatus();
    }
    if (Platform.isMacOS) {
      return _readMacOSStatus();
    }
    if (Platform.isWindows) {
      return _readWindowsStatus();
    }
    return null;
  }

  Map<String, Object?>? _normalizeNativeStatus(Object? value) {
    if (value is! Map) {
      return null;
    }
    final normalized = <String, Object?>{};
    for (final entry in value.entries) {
      normalized[entry.key.toString()] = entry.value;
    }
    return normalized;
  }

  Future<Map<String, Object?>?> _readLinuxStatus() async {
    final powerSupply = Directory('/sys/class/power_supply');
    if (!await powerSupply.exists()) {
      return null;
    }
    await for (final entity in powerSupply.list()) {
      if (entity is! Directory ||
          !entity.path.split(Platform.pathSeparator).last.startsWith('BAT')) {
        continue;
      }
      final capacity = await _readTrimmedFile('${entity.path}/capacity');
      final rawState = await _readTrimmedFile('${entity.path}/status');
      final batteryPercent = int.tryParse(capacity ?? '');
      final chargingState = switch (rawState?.toLowerCase()) {
        'charging' => 'charging',
        'discharging' => 'discharging',
        'full' => 'full',
        'not charging' => 'notCharging',
        _ => 'unknown',
      };
      return {
        if (batteryPercent != null) 'batteryPercent': batteryPercent,
        'chargingState': chargingState,
        'powerSource': chargingState == 'charging' || chargingState == 'full'
            ? 'ac'
            : 'battery',
        'sourcePlatform': 'linux',
      };
    }
    return null;
  }

  Future<Map<String, Object?>?> _readWindowsStatus() async {
    final getSystemPowerStatus = ffi.DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<SystemPowerStatus>),
            int Function(
                ffi.Pointer<SystemPowerStatus>)>('GetSystemPowerStatus');
    final status = calloc<SystemPowerStatus>();
    try {
      if (getSystemPowerStatus(status) == 0) {
        return null;
      }
      final batteryPercent = status.ref.batteryLifePercent == 255
          ? null
          : status.ref.batteryLifePercent;
      final powerSource = switch (status.ref.acLineStatus) {
        0 => 'battery',
        1 => 'ac',
        _ => 'unknown',
      };
      final chargingState = powerSource == 'ac'
          ? (batteryPercent == 100 ? 'full' : 'charging')
          : powerSource == 'battery'
              ? 'discharging'
              : 'unknown';
      return {
        if (batteryPercent != null) 'batteryPercent': batteryPercent,
        'chargingState': chargingState,
        'powerSource': powerSource,
        'sourcePlatform': 'windows',
      };
    } finally {
      calloc.free(status);
    }
  }

  Future<Map<String, Object?>?> _readMacOSStatus() async {
    final result = await Process.run('/usr/bin/pmset', const ['-g', 'batt']);
    if (result.exitCode != 0) {
      return null;
    }
    final output = result.stdout.toString();
    final percentMatch = RegExp(r'(\d{1,3})%').firstMatch(output);
    final batteryPercent = int.tryParse(percentMatch?.group(1) ?? '');
    final lower = output.toLowerCase();
    final chargingState = lower.contains('; charging;')
        ? 'charging'
        : lower.contains('; charged;')
            ? 'full'
            : lower.contains('; discharging;')
                ? 'discharging'
                : 'unknown';
    return {
      if (batteryPercent != null) 'batteryPercent': batteryPercent,
      'chargingState': chargingState,
      'powerSource': output.contains("'AC Power'") ? 'ac' : 'battery',
      'sourcePlatform': 'macos',
    };
  }

  Future<String?> _readTrimmedFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    return (await file.readAsString()).trim();
  }
}
