import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MirroredNotificationEntry {
  const MirroredNotificationEntry({
    required this.mirrorKey,
    required this.sourceDeviceId,
    required this.notificationId,
  });

  final String mirrorKey;
  final String sourceDeviceId;
  final String notificationId;

  Map<String, String> toJson() => <String, String>{
        'mirrorKey': mirrorKey,
        'sourceDeviceId': sourceDeviceId,
        'notificationId': notificationId,
      };

  static MirroredNotificationEntry? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final mirrorKey = value['mirrorKey'];
    final sourceDeviceId = value['sourceDeviceId'];
    final notificationId = value['notificationId'];
    if (mirrorKey is! String ||
        mirrorKey.isEmpty ||
        sourceDeviceId is! String ||
        sourceDeviceId.isEmpty ||
        notificationId is! String ||
        notificationId.isEmpty) {
      return null;
    }
    return MirroredNotificationEntry(
      mirrorKey: mirrorKey,
      sourceDeviceId: sourceDeviceId,
      notificationId: notificationId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MirroredNotificationEntry &&
      other.mirrorKey == mirrorKey &&
      other.sourceDeviceId == sourceDeviceId &&
      other.notificationId == notificationId;

  @override
  int get hashCode => Object.hash(
        mirrorKey,
        sourceDeviceId,
        notificationId,
      );
}

class MirroredNotificationRegistry {
  static const String preferenceKey = 'mirrored_notification_registry_v1';
  static const int _version = 1;
  static const int maxEntries = 1024;

  MirroredNotificationRegistry._(
      this._preferences, Map<String, MirroredNotificationEntry> entries)
      : _entries =
            LinkedHashMap<String, MirroredNotificationEntry>.from(entries);

  final SharedPreferences _preferences;
  final LinkedHashMap<String, MirroredNotificationEntry> _entries;
  Future<void> _pendingWrite = Future<void>.value();

  static Future<MirroredNotificationRegistry> load({
    SharedPreferences? preferences,
  }) async {
    final resolvedPreferences =
        preferences ?? await SharedPreferences.getInstance();
    final registry = MirroredNotificationRegistry._(
      resolvedPreferences,
      <String, MirroredNotificationEntry>{},
    );
    await registry.reload();
    return registry;
  }

  List<MirroredNotificationEntry> get entries =>
      List<MirroredNotificationEntry>.unmodifiable(_entries.values);

  bool contains(String mirrorKey) => _entries.containsKey(mirrorKey);

  Future<void> reload() async {
    await _pendingWrite;
    await _preferences.reload();

    final raw = _preferences.getString(preferenceKey);
    final decoded = _decode(raw);
    if (decoded == null) {
      _entries.clear();
      if (raw != null) {
        debugPrint(
          '[Notification Mirror] Discarding malformed persisted registry.',
        );
        await _preferences.remove(preferenceKey);
      }
      return;
    }

    _entries
      ..clear()
      ..addAll(decoded);
  }

  Future<void> remember(MirroredNotificationEntry entry) async {
    _entries.remove(entry.mirrorKey);
    _entries[entry.mirrorKey] = entry;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    await _persist();
  }

  Future<void> forget(String mirrorKey) async {
    if (_entries.remove(mirrorKey) == null) {
      return;
    }
    await _persist();
  }

  Future<void> clear() async {
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    await _persist();
  }

  Map<String, MirroredNotificationEntry>? _decode(String? raw) {
    if (raw == null) {
      return <String, MirroredNotificationEntry>{};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != _version) {
        return null;
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is! List) {
        return null;
      }

      final entries = <String, MirroredNotificationEntry>{};
      for (final rawEntry in rawEntries) {
        final entry = MirroredNotificationEntry.fromJson(rawEntry);
        if (entry == null) {
          return null;
        }
        entries[entry.mirrorKey] = entry;
      }
      final boundedEntries = LinkedHashMap<String, MirroredNotificationEntry>();
      final skipCount =
          entries.length > maxEntries ? entries.length - maxEntries : 0;
      for (final entry in entries.entries.skip(skipCount)) {
        boundedEntries[entry.key] = entry.value;
      }
      return boundedEntries;
    } on Object catch (error) {
      debugPrint('[Notification Mirror] Failed to decode registry: $error');
      return null;
    }
  }

  Future<void> _persist() {
    final snapshot = jsonEncode(<String, Object?>{
      'version': _version,
      'entries': _entries.values.map((entry) => entry.toJson()).toList(),
    });
    final previous = _pendingWrite;
    final next = previous.catchError((_) {}).then((_) async {
      await _preferences.setString(preferenceKey, snapshot);
    });
    _pendingWrite = next;
    return next;
  }
}
