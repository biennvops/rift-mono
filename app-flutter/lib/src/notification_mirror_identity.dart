import 'dart:convert';

import 'package:crypto/crypto.dart';

const String mirroredNotificationKeyPrefix = 'rift.mirror.v1.';

String mirroredNotificationKey({
  required String sourceDeviceId,
  required String notificationId,
}) {
  if (sourceDeviceId.isEmpty) {
    throw ArgumentError.value(sourceDeviceId, 'sourceDeviceId');
  }
  if (notificationId.isEmpty) {
    throw ArgumentError.value(notificationId, 'notificationId');
  }

  final input = utf8.encode('$sourceDeviceId\u0000$notificationId');
  final digest = sha256.convert(input).toString();
  return '$mirroredNotificationKeyPrefix$digest';
}
