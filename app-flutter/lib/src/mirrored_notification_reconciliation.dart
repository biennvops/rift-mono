import 'package:flutter/foundation.dart';

import 'ipc/json_rpc_client.dart';
import 'mirrored_notification_registry.dart';
import 'notification_mirror_identity.dart';

Future<void> reconcileMirroredNotificationPreviews({
  required JsonRpcRiftClient client,
  required MirroredNotificationRegistry registry,
  required Future<String?> Function() getLocalDeviceId,
  required Future<bool> Function(String mirrorKey) clearNativeNotification,
}) async {
  if (!client.isConnected) {
    return;
  }

  final localDeviceId = await getLocalDeviceId();
  if (localDeviceId == null) {
    debugPrint(
      '[Notification Mirror] Cannot reconcile without the local device ID.',
    );
    return;
  }

  await registry.reload();

  dynamic result;
  try {
    result = await client.listNotifications();
  } catch (error) {
    debugPrint('[Notification Mirror] Failed to list notifications: $error');
    return;
  }
  if (result is! Map || result['notifications'] is! List) {
    debugPrint('[Notification Mirror] Invalid listNotifications response.');
    return;
  }

  final activeKeys = <String>{};
  for (final value in result['notifications'] as List) {
    if (value is! Map) {
      continue;
    }
    final sourceDeviceId = value['sourceDeviceId']?.toString();
    final notificationId = value['notificationId']?.toString();
    if (sourceDeviceId == null ||
        sourceDeviceId.isEmpty ||
        notificationId == null ||
        notificationId.isEmpty ||
        sourceDeviceId == localDeviceId) {
      continue;
    }
    activeKeys.add(
      mirroredNotificationKey(
        sourceDeviceId: sourceDeviceId,
        notificationId: notificationId,
      ),
    );
  }

  final staleEntries = registry.entries
      .where((entry) => !activeKeys.contains(entry.mirrorKey))
      .toList(growable: false);
  for (final entry in staleEntries) {
    if (await clearNativeNotification(entry.mirrorKey)) {
      await registry.forget(entry.mirrorKey);
    }
  }
}
