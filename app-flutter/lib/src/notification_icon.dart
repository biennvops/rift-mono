import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const int notificationIconMaxRawBytes = 131072;
const int notificationIconMaxBase64Characters =
    ((notificationIconMaxRawBytes + 2) ~/ 3) * 4;
const int notificationIconMaxDimension = 512;
const _notificationIconCanonicalFields = <String>{
  'mediaType',
  'dataBase64',
  'byteSize',
  'sha256',
};
const _pngSignature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
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

const _notificationIconCacheMaxEntries = 128;
final _notificationIconCache = <String, _CachedNotificationIcon>{};

class _CachedNotificationIcon {
  const _CachedNotificationIcon({
    required this.dataBase64,
    required this.byteSize,
    required this.icon,
  });

  final String dataBase64;
  final int byteSize;
  final NotificationIcon icon;
}

@visibleForTesting
void clearNotificationIconCache() => _notificationIconCache.clear();

Map<String, Object?>? createNotificationIconPayload(Uint8List pngBytes) {
  if (pngBytes.isEmpty ||
      pngBytes.length > notificationIconMaxRawBytes ||
      !_isValidNotificationPng(pngBytes)) {
    return null;
  }

  return <String, Object?>{
    'mediaType': 'image/png',
    'dataBase64': base64Encode(pngBytes),
    'byteSize': pngBytes.length,
    'sha256': sha256.convert(pngBytes).toString(),
  };
}

NotificationIcon? parseNotificationIcon(Object? value) {
  if (value is! Map) {
    return null;
  }

  if (value.length != _notificationIconCanonicalFields.length ||
      value.keys.any(
        (key) =>
            key is! String || !_notificationIconCanonicalFields.contains(key),
      )) {
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

  final cached = _notificationIconCache[sha256Value];
  if (cached != null &&
      cached.dataBase64 == dataBase64 &&
      cached.byteSize == byteSize) {
    return cached.icon;
  }

  Uint8List bytes;
  try {
    bytes = Uint8List.fromList(base64Decode(dataBase64));
  } catch (_) {
    return null;
  }
  if (bytes.length > notificationIconMaxRawBytes ||
      bytes.length != byteSize ||
      !_isValidNotificationPng(bytes) ||
      sha256.convert(bytes).toString() != sha256Value) {
    return null;
  }

  final icon = NotificationIcon(
    mediaType: 'image/png',
    bytes: bytes,
    sha256: sha256Value,
  );
  if (!_notificationIconCache.containsKey(sha256Value) &&
      _notificationIconCache.length >= _notificationIconCacheMaxEntries) {
    _notificationIconCache.remove(_notificationIconCache.keys.first);
  }
  _notificationIconCache[sha256Value] = _CachedNotificationIcon(
    dataBase64: dataBase64,
    byteSize: byteSize,
    icon: icon,
  );
  return icon;
}

bool _isValidNotificationPng(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) {
    return false;
  }
  for (var index = 0; index < _pngSignature.length; index++) {
    if (bytes[index] != _pngSignature[index]) {
      return false;
    }
  }

  var offset = _pngSignature.length;
  var chunkIndex = 0;
  var sawHeader = false;
  var sawPalette = false;
  var sawImageData = false;
  var finishedImageData = false;
  var imageDataBytes = 0;
  var colorType = 0;

  while (offset <= bytes.length - 12) {
    final dataLength = _readPngUint32(bytes, offset);
    if (dataLength > bytes.length - offset - 12) {
      return false;
    }
    final typeOffset = offset + 4;
    final dataOffset = offset + 8;
    final expectedCrc = _readPngUint32(bytes, dataOffset + dataLength);
    if (!_isPngChunkType(bytes, typeOffset) ||
        _pngChunkCrc32(bytes, typeOffset, dataOffset, dataLength) !=
            expectedCrc) {
      return false;
    }

    final isHeader = _isPngChunk(bytes, typeOffset, 0x49, 0x48, 0x44, 0x52);
    final isPalette = _isPngChunk(bytes, typeOffset, 0x50, 0x4c, 0x54, 0x45);
    final isImageData = _isPngChunk(bytes, typeOffset, 0x49, 0x44, 0x41, 0x54);
    final isEnd = _isPngChunk(bytes, typeOffset, 0x49, 0x45, 0x4e, 0x44);
    if ((chunkIndex == 0 && !isHeader) || (chunkIndex > 0 && isHeader)) {
      return false;
    }

    if (isHeader) {
      if (dataLength != 13 || !_isValidPngHeader(bytes, dataOffset)) {
        return false;
      }
      colorType = bytes[dataOffset + 9];
      sawHeader = true;
    } else if (isPalette) {
      if (!sawHeader ||
          sawPalette ||
          sawImageData ||
          colorType == 0 ||
          colorType == 4 ||
          dataLength == 0 ||
          dataLength % 3 != 0 ||
          dataLength > 768) {
        return false;
      }
      sawPalette = true;
    } else if (isImageData) {
      if (!sawHeader || finishedImageData || (colorType == 3 && !sawPalette)) {
        return false;
      }
      sawImageData = true;
      imageDataBytes += dataLength;
    } else {
      if (sawImageData) {
        finishedImageData = true;
      }
      if (isEnd) {
        return dataLength == 0 &&
            sawImageData &&
            imageDataBytes > 0 &&
            offset + 12 == bytes.length;
      }
      if ((bytes[typeOffset] & 0x20) == 0) {
        return false;
      }
    }

    offset += dataLength + 12;
    chunkIndex++;
  }
  return false;
}

bool _isValidPngHeader(Uint8List bytes, int offset) {
  final width = _readPngUint32(bytes, offset);
  final height = _readPngUint32(bytes, offset + 4);
  final bitDepth = bytes[offset + 8];
  final colorType = bytes[offset + 9];
  final validBitDepth = switch (colorType) {
    0 => bitDepth == 1 ||
        bitDepth == 2 ||
        bitDepth == 4 ||
        bitDepth == 8 ||
        bitDepth == 16,
    2 || 4 || 6 => bitDepth == 8 || bitDepth == 16,
    3 => bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8,
    _ => false,
  };
  return width > 0 &&
      width <= notificationIconMaxDimension &&
      height > 0 &&
      height <= notificationIconMaxDimension &&
      validBitDepth &&
      bytes[offset + 10] == 0 &&
      bytes[offset + 11] == 0 &&
      (bytes[offset + 12] == 0 || bytes[offset + 12] == 1);
}

int _readPngUint32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);

bool _isPngChunkType(Uint8List bytes, int offset) {
  for (var index = offset; index < offset + 4; index++) {
    final value = bytes[index];
    if (!((value >= 0x41 && value <= 0x5a) ||
        (value >= 0x61 && value <= 0x7a))) {
      return false;
    }
  }
  return (bytes[offset + 2] & 0x20) == 0;
}

bool _isPngChunk(
  Uint8List bytes,
  int offset,
  int first,
  int second,
  int third,
  int fourth,
) =>
    bytes[offset] == first &&
    bytes[offset + 1] == second &&
    bytes[offset + 2] == third &&
    bytes[offset + 3] == fourth;

int _pngChunkCrc32(
  Uint8List bytes,
  int typeOffset,
  int dataOffset,
  int dataLength,
) {
  var crc = 0xffffffff;
  for (var index = typeOffset; index < typeOffset + 4; index++) {
    crc = _updatePngCrc32(crc, bytes[index]);
  }
  for (var index = dataOffset; index < dataOffset + dataLength; index++) {
    crc = _updatePngCrc32(crc, bytes[index]);
  }
  return (~crc) & 0xffffffff;
}

int _updatePngCrc32(int crc, int value) {
  var updated = crc ^ value;
  for (var bit = 0; bit < 8; bit++) {
    updated = (updated & 1) != 0 ? (updated >> 1) ^ 0xedb88320 : updated >> 1;
  }
  return updated;
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
