import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/notification_mirror_identity.dart';

void main() {
  test('is deterministic for the same source identity', () {
    expect(
      mirroredNotificationKey(
        sourceDeviceId: 'device-a',
        notificationId: 'notification-1',
      ),
      mirroredNotificationKey(
        sourceDeviceId: 'device-a',
        notificationId: 'notification-1',
      ),
    );
  });

  test('is scoped to the source device and notification id', () {
    final sourceA = mirroredNotificationKey(
      sourceDeviceId: 'device-a',
      notificationId: 'same-id',
    );
    final sourceB = mirroredNotificationKey(
      sourceDeviceId: 'device-b',
      notificationId: 'same-id',
    );
    final notificationB = mirroredNotificationKey(
      sourceDeviceId: 'device-a',
      notificationId: 'other-id',
    );

    expect(sourceA, isNot(sourceB));
    expect(sourceA, isNot(notificationB));
    expect(sourceB, isNot(notificationB));
  });

  test('uses an unambiguous delimiter between identity components', () {
    expect(
      mirroredNotificationKey(
        sourceDeviceId: 'ab',
        notificationId: 'c',
      ),
      isNot(
        mirroredNotificationKey(
          sourceDeviceId: 'a',
          notificationId: 'bc',
        ),
      ),
    );
  });

  test('has a bounded native-safe format for long identities', () {
    final key = mirroredNotificationKey(
      sourceDeviceId: 'source-${'x' * 10000}',
      notificationId: 'notification-${'y' * 10000}',
    );

    expect(key, startsWith(mirroredNotificationKeyPrefix));
    expect(key, matches(RegExp(r'^rift\.mirror\.v1\.[0-9a-f]{64}$')));
    expect(key.length, mirroredNotificationKeyPrefix.length + 64);
  });

  test('rejects empty protocol identity components', () {
    expect(
      () => mirroredNotificationKey(
        sourceDeviceId: '',
        notificationId: 'notification-1',
      ),
      throwsArgumentError,
    );
    expect(
      () => mirroredNotificationKey(
        sourceDeviceId: 'device-a',
        notificationId: '',
      ),
      throwsArgumentError,
    );
  });
}
