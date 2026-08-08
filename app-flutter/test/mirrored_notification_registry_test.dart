import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/mirrored_notification_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

MirroredNotificationEntry entry(String suffix) => MirroredNotificationEntry(
      mirrorKey: 'rift.mirror.v1.$suffix',
      sourceDeviceId: 'source-$suffix',
      notificationId: 'notification-$suffix',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('remembers entries and duplicate keys remain one entry', () async {
    final registry = await MirroredNotificationRegistry.load();
    final first = entry('one');
    final replacement = MirroredNotificationEntry(
      mirrorKey: first.mirrorKey,
      sourceDeviceId: 'source-replacement',
      notificationId: 'notification-replacement',
    );

    await registry.remember(first);
    await registry.remember(replacement);

    expect(registry.entries, [replacement]);
  });

  test('forgets an entry and persists the removal', () async {
    final registry = await MirroredNotificationRegistry.load();
    final saved = entry('one');
    await registry.remember(saved);
    await registry.forget(saved.mirrorKey);

    final reloaded = await MirroredNotificationRegistry.load();
    expect(reloaded.entries, isEmpty);
  });

  test('round-trips entries through versioned JSON preferences', () async {
    final registry = await MirroredNotificationRegistry.load();
    final saved = entry('one');
    await registry.remember(saved);

    final preferences = await SharedPreferences.getInstance();
    final persisted = jsonDecode(
      preferences.getString(MirroredNotificationRegistry.preferenceKey)!,
    ) as Map<String, dynamic>;
    expect(persisted['version'], 1);
    expect(persisted['entries'], hasLength(1));

    final reloaded = await MirroredNotificationRegistry.load();
    expect(reloaded.entries, [saved]);
  });

  test('keeps same notification IDs from different sources separate', () async {
    final registry = await MirroredNotificationRegistry.load();
    await registry.remember(
      const MirroredNotificationEntry(
        mirrorKey: 'key-a',
        sourceDeviceId: 'source-a',
        notificationId: 'same-id',
      ),
    );
    await registry.remember(
      const MirroredNotificationEntry(
        mirrorKey: 'key-b',
        sourceDeviceId: 'source-b',
        notificationId: 'same-id',
      ),
    );

    expect(registry.entries, hasLength(2));
  });

  test('discards malformed persisted JSON without throwing', () async {
    SharedPreferences.setMockInitialValues({
      MirroredNotificationRegistry.preferenceKey: '{not-json',
    });

    final registry = await MirroredNotificationRegistry.load();

    expect(registry.entries, isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(MirroredNotificationRegistry.preferenceKey),
      isNull,
    );
  });

  test('bounds the registry by retaining the newest entries', () async {
    final registry = await MirroredNotificationRegistry.load();
    for (var index = 0;
        index < MirroredNotificationRegistry.maxEntries + 1;
        index++) {
      await registry.remember(entry('$index'));
    }

    expect(
        registry.entries, hasLength(MirroredNotificationRegistry.maxEntries));
    expect(registry.entries.first, entry('1'));
    expect(registry.entries.last,
        entry('${MirroredNotificationRegistry.maxEntries}'));
  });
}
