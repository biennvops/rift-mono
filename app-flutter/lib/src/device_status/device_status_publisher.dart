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
        batteryPresent: status['batteryPresent'] as bool?,
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
    if (previous['batteryPresent'] != status['batteryPresent']) {
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
    final supplies = await powerSupply
        .list()
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    final externalPowerOnline = await _readLinuxExternalPowerOnline(supplies);

    for (final entity in supplies) {
      if (!entity.path.split(Platform.pathSeparator).last.startsWith('BAT')) {
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
        'batteryPresent': true,
        if (batteryPercent != null) 'batteryPercent': batteryPercent,
        'chargingState': chargingState,
        'powerSource': deriveLinuxPowerSource(
          chargingState: chargingState,
          externalPowerOnline: externalPowerOnline,
        ),
        'sourcePlatform': 'linux',
      };
    }
    return {
      'batteryPresent': false,
      'powerSource': externalPowerOnline == true ? 'ac' : 'unknown',
      'sourcePlatform': 'linux',
    };
  }

  Future<bool?> _readLinuxExternalPowerOnline(
    List<Directory> supplies,
  ) async {
    var sawOfflineSupply = false;
    for (final supply in supplies) {
      final name = supply.path.split(Platform.pathSeparator).last;
      if (name.startsWith('BAT')) {
        continue;
      }
      final type =
          (await _readTrimmedFile('${supply.path}/type'))?.toLowerCase();
      if (type == 'battery') {
        continue;
      }
      final online = await _readTrimmedFile('${supply.path}/online');
      if (online == '1') {
        return true;
      }
      if (online == '0') {
        sawOfflineSupply = true;
      }
    }
    return sawOfflineSupply ? false : null;
  }

  @visibleForTesting
  static String deriveLinuxPowerSource({
    required String chargingState,
    required bool? externalPowerOnline,
  }) {
    if (externalPowerOnline == true) {
      return 'ac';
    }
    if (externalPowerOnline == false) {
      return 'battery';
    }
    return switch (chargingState) {
      'charging' || 'full' => 'ac',
      'discharging' => 'battery',
      _ => 'unknown',
    };
  }

  @visibleForTesting
  static Map<String, Object?> parseWindowsPowerStatus({
    required int acLineStatus,
    required int batteryFlag,
    required int batteryLifePercent,
  }) {
    final batteryPresent =
        batteryFlag == 255 ? null : (batteryFlag & 0x80) == 0;
    final batteryPercent = batteryPresent == false || batteryLifePercent == 255
        ? null
        : batteryLifePercent;
    final powerSource = switch (acLineStatus) {
      0 => 'battery',
      1 => 'ac',
      _ => 'unknown',
    };
    final isCharging = batteryFlag != 255 && (batteryFlag & 0x08) != 0;
    final chargingState = batteryPresent == false
        ? null
        : batteryPercent == 100
            ? 'full'
            : isCharging
                ? 'charging'
                : powerSource == 'ac'
                    ? 'notCharging'
                    : powerSource == 'battery'
                        ? 'discharging'
                        : 'unknown';
    return {
      if (batteryPresent != null) 'batteryPresent': batteryPresent,
      if (batteryPercent != null) 'batteryPercent': batteryPercent,
      if (chargingState != null) 'chargingState': chargingState,
      'powerSource': powerSource,
      'sourcePlatform': 'windows',
    };
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
      return parseWindowsPowerStatus(
        acLineStatus: status.ref.acLineStatus,
        batteryFlag: status.ref.batteryFlag,
        batteryLifePercent: status.ref.batteryLifePercent,
      );
    } finally {
      calloc.free(status);
    }
  }

  @visibleForTesting
  static Map<String, Object?> parseMacOSPowerStatus(String output) {
    final lower = output.toLowerCase();
    final batteryPresent = !lower.contains('no battery');
    final percentMatch = RegExp(r'(\d{1,3})%').firstMatch(output);
    final batteryPercent =
        batteryPresent ? int.tryParse(percentMatch?.group(1) ?? '') : null;
    final chargingState = lower.contains('not charging')
        ? 'notCharging'
        : lower.contains('; charging;')
            ? 'charging'
            : lower.contains('; charged;')
                ? 'full'
                : lower.contains('; discharging;')
                    ? 'discharging'
                    : 'unknown';
    return {
      'batteryPresent': batteryPresent,
      if (batteryPercent != null) 'batteryPercent': batteryPercent,
      if (batteryPresent) 'chargingState': chargingState,
      'powerSource': output.contains("'AC Power'") ? 'ac' : 'battery',
      'sourcePlatform': 'macos',
    };
  }

  Future<Map<String, Object?>?> _readMacOSStatus() async {
    final result = await Process.run('/usr/bin/pmset', const ['-g', 'batt']);
    if (result.exitCode != 0) {
      return null;
    }
    return parseMacOSPowerStatus(result.stdout.toString());
  }

  Future<String?> _readTrimmedFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    return (await file.readAsString()).trim();
  }
}
