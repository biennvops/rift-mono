import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'ipc/json_rpc_client.dart';

enum NotificationSyncPolicyMode {
  all,
  exclude,
  include,
}

String notificationSyncPolicyModeToWire(NotificationSyncPolicyMode mode) {
  switch (mode) {
    case NotificationSyncPolicyMode.all:
      return 'all';
    case NotificationSyncPolicyMode.exclude:
      return 'exclude';
    case NotificationSyncPolicyMode.include:
      return 'include';
  }
}

NotificationSyncPolicyMode notificationSyncPolicyModeFromWire(String value) {
  switch (value) {
    case 'all':
      return NotificationSyncPolicyMode.all;
    case 'exclude':
      return NotificationSyncPolicyMode.exclude;
    case 'include':
      return NotificationSyncPolicyMode.include;
    default:
      throw FormatException('Invalid notification sync policy mode: $value');
  }
}

List<String> normalizeNotificationPackageNames(Iterable<String> values) {
  final normalized = values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList();
  return normalized..sort();
}

class NotificationSyncPolicyPreferences {
  final bool enabled;
  final NotificationSyncPolicyMode mode;
  final List<String> packageNames;

  NotificationSyncPolicyPreferences({
    required this.enabled,
    required this.mode,
    Iterable<String> packageNames = const <String>[],
  }) : packageNames = List.unmodifiable(
          normalizeNotificationPackageNames(packageNames),
        );
}

class NotificationSyncObservedApp {
  final String packageName;
  final String appName;

  const NotificationSyncObservedApp({
    required this.packageName,
    required this.appName,
  });
}

class _LegacyNotificationSyncPolicy {
  final bool enabled;
  final List<String> packageNames;
  final bool isPresent;

  const _LegacyNotificationSyncPolicy({
    required this.enabled,
    required this.packageNames,
    required this.isPresent,
  });
}

Future<NotificationSyncPolicyPreferences>
    loadNotificationSyncPolicyPreferences() async {
  final prefs = await SharedPreferences.getInstance();
  final v2 = _loadV2Preferences(prefs);
  if (v2 != null) {
    final legacy = _loadLegacyPreferences(prefs);
    final expectedLegacy =
        _loadLegacyProjection(prefs) ?? _legacyProjectionForPolicy(v2);
    if (legacy.isPresent && !_legacyPoliciesEqual(legacy, expectedLegacy)) {
      final migrated = _policyFromLegacy(legacy);
      await _persistPolicy(prefs, migrated);
      return migrated;
    }

    await _persistPolicy(prefs, v2);
    return v2;
  }

  final legacy = _loadLegacyPreferences(prefs);
  final policy = _policyFromLegacy(legacy);
  await _persistPolicy(prefs, policy);
  return policy;
}

Future<void> persistNotificationSyncPolicyPreferences({
  required bool enabled,
  required NotificationSyncPolicyMode mode,
  required List<String> packageNames,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final policy = NotificationSyncPolicyPreferences(
    enabled: enabled,
    mode: mode,
    packageNames: packageNames,
  );
  await _persistPolicy(prefs, policy);
}

Future<void> pushSavedNotificationSyncPolicy(
  JsonRpcRiftClient client,
) async {
  if (!client.isConnected) {
    return;
  }

  final policy = await loadNotificationSyncPolicyPreferences();
  await client.updateNotificationSyncPolicy(
    enabled: policy.enabled,
    mode: notificationSyncPolicyModeToWire(policy.mode),
    packageNames: policy.packageNames,
  );
}

_LegacyNotificationSyncPolicy _loadLegacyPreferences(
  SharedPreferences prefs,
) {
  final isPresent = prefs.containsKey(AppPrefs.notificationSyncEnabled) ||
      prefs.containsKey(AppPrefs.notificationSyncBlacklist);
  try {
    return _LegacyNotificationSyncPolicy(
      enabled: prefs.getBool(AppPrefs.notificationSyncEnabled) ?? true,
      packageNames: normalizeNotificationPackageNames(
        prefs.getStringList(AppPrefs.notificationSyncBlacklist) ??
            const <String>[],
      ),
      isPresent: isPresent,
    );
  } catch (_) {
    return _LegacyNotificationSyncPolicy(
      enabled: true,
      packageNames: const <String>[],
      isPresent: isPresent,
    );
  }
}

NotificationSyncPolicyPreferences _policyFromLegacy(
  _LegacyNotificationSyncPolicy legacy,
) {
  return NotificationSyncPolicyPreferences(
    enabled: legacy.enabled,
    mode: legacy.packageNames.isEmpty
        ? NotificationSyncPolicyMode.all
        : NotificationSyncPolicyMode.exclude,
    packageNames: legacy.packageNames,
  );
}

_LegacyNotificationSyncPolicy _legacyProjectionForPolicy(
  NotificationSyncPolicyPreferences policy,
) {
  return _LegacyNotificationSyncPolicy(
    enabled: policy.mode == NotificationSyncPolicyMode.include
        ? false
        : policy.enabled,
    packageNames: policy.mode == NotificationSyncPolicyMode.exclude
        ? policy.packageNames
        : const <String>[],
    isPresent: true,
  );
}

bool _legacyPoliciesEqual(
  _LegacyNotificationSyncPolicy first,
  _LegacyNotificationSyncPolicy second,
) {
  if (first.enabled != second.enabled ||
      first.packageNames.length != second.packageNames.length) {
    return false;
  }
  for (var index = 0; index < first.packageNames.length; index++) {
    if (first.packageNames[index] != second.packageNames[index]) {
      return false;
    }
  }
  return true;
}

_LegacyNotificationSyncPolicy? _loadLegacyProjection(
  SharedPreferences prefs,
) {
  try {
    final raw =
        prefs.getString(AppPrefs.notificationSyncPolicyLegacyProjectionV2);
    if (raw == null) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['enabled'] is! bool) {
      return null;
    }
    final packageNames = decoded['blacklistedPackages'];
    if (packageNames is! List ||
        packageNames.any((value) => value is! String)) {
      return null;
    }
    return _LegacyNotificationSyncPolicy(
      enabled: decoded['enabled'] as bool,
      packageNames: normalizeNotificationPackageNames(
        packageNames.cast<String>(),
      ),
      isPresent: true,
    );
  } catch (_) {
    return null;
  }
}

NotificationSyncPolicyPreferences? _loadV2Preferences(
  SharedPreferences prefs,
) {
  if (!prefs.containsKey(AppPrefs.notificationSyncPolicyEnabledV2) ||
      !prefs.containsKey(AppPrefs.notificationSyncPolicyModeV2) ||
      !prefs.containsKey(AppPrefs.notificationSyncPolicyPackagesV2)) {
    return null;
  }

  try {
    final enabled = prefs.getBool(AppPrefs.notificationSyncPolicyEnabledV2);
    final modeValue = prefs.getString(AppPrefs.notificationSyncPolicyModeV2);
    final packageNames =
        prefs.getStringList(AppPrefs.notificationSyncPolicyPackagesV2);
    if (enabled == null || modeValue == null || packageNames == null) {
      return null;
    }

    return NotificationSyncPolicyPreferences(
      enabled: enabled,
      mode: notificationSyncPolicyModeFromWire(modeValue),
      packageNames: packageNames,
    );
  } catch (_) {
    return null;
  }
}

Future<void> _persistPolicy(
  SharedPreferences prefs,
  NotificationSyncPolicyPreferences policy,
) async {
  final packageNames = policy.packageNames;
  final modeValue = notificationSyncPolicyModeToWire(policy.mode);
  await prefs.setBool(AppPrefs.notificationSyncPolicyEnabledV2, policy.enabled);
  await prefs.setString(AppPrefs.notificationSyncPolicyModeV2, modeValue);
  await prefs.setStringList(
    AppPrefs.notificationSyncPolicyPackagesV2,
    packageNames,
  );

  final legacyEnabled = policy.mode == NotificationSyncPolicyMode.include
      ? false
      : policy.enabled;
  final legacyPackages = policy.mode == NotificationSyncPolicyMode.exclude
      ? packageNames
      : const <String>[];
  await prefs.setBool(AppPrefs.notificationSyncEnabled, legacyEnabled);
  await prefs.setStringList(AppPrefs.notificationSyncBlacklist, legacyPackages);
  await prefs.setString(
    AppPrefs.notificationSyncPolicyLegacyProjectionV2,
    jsonEncode({
      'enabled': legacyEnabled,
      'blacklistedPackages': legacyPackages,
    }),
  );
}
