import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

const int notificationIconMaxRawBytes = 131072;
const int notificationIconMaxBase64Characters =
    ((notificationIconMaxRawBytes + 2) ~/ 3) * 4;
final _notificationIconSha256Pattern = RegExp(r'^[0-9a-f]{64}$');

class NotificationIcon {
  const NotificationIcon({
    required this.mediaType,
    required this.bytes,
    required this.sha256,
  });

  final String mediaType;
  final Uint8List bytes;
  final String sha256;
}

NotificationIcon? parseNotificationIcon(Object? value) {
  if (value is! Map) {
    return null;
  }

  final mediaType = value['mediaType'];
  final dataBase64 = value['dataBase64'];
  final byteSize = value['byteSize'];
  final sha256Value = value['sha256'];
  if (mediaType != 'image/png' ||
      dataBase64 is! String ||
      dataBase64.length > notificationIconMaxBase64Characters ||
      byteSize is! int ||
      byteSize < 0 ||
      byteSize > notificationIconMaxRawBytes ||
      sha256Value is! String ||
      !_notificationIconSha256Pattern.hasMatch(sha256Value)) {
    return null;
  }

  Uint8List bytes;
  try {
    bytes = Uint8List.fromList(base64Decode(dataBase64));
  } catch (_) {
    return null;
  }
  if (bytes.length > notificationIconMaxRawBytes ||
      bytes.length != byteSize ||
      sha256.convert(bytes).toString() != sha256Value) {
    return null;
  }

  return NotificationIcon(
    mediaType: 'image/png',
    bytes: bytes,
    sha256: sha256Value,
  );
}

class NotificationAppIcon extends StatelessWidget {
  const NotificationAppIcon({
    super.key,
    required this.metadata,
    this.size = 44,
    this.fallbackIcon = Icons.notifications_outlined,
  });

  final Object? metadata;
  final double size;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final icon = parseNotificationIcon(metadata);
    if (icon == null) {
      return _fallback(context);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.memory(
        icon.bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stackTrace) => _fallback(context),
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    final theme = Theme.of(context);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundColor: theme.colorScheme.onPrimaryContainer,
      child: Icon(fallbackIcon, size: size * 0.45),
    );
  }
}
