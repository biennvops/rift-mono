import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IOSClipboardContent {
  const IOSClipboardContent({
    required this.contentType,
    required this.bytes,
  });

  final String contentType;
  final Uint8List bytes;
}

class IOSClipboard {
  static const MethodChannel _channel = MethodChannel('rift/ios/clipboard');

  @visibleForTesting
  static bool? debugIsIOSOverride;

  static bool get isSupported => debugIsIOSOverride ?? Platform.isIOS;

  static Future<IOSClipboardContent?> readContent() async {
    if (!isSupported) return null;
    final result = await _channel.invokeMethod<Object>('readContent');
    if (result is! Map) return null;

    final contentType = result['contentType']?.toString();
    final bytes = result['bytes'];
    if (contentType == null || bytes is! Uint8List) return null;
    return IOSClipboardContent(contentType: contentType, bytes: bytes);
  }

  static Future<bool> writeContent(IOSClipboardContent content) async {
    if (!isSupported) return false;
    final written = await _channel.invokeMethod<bool>('writeContent', {
      'contentType': content.contentType,
      'bytes': content.bytes,
    });
    return written ?? false;
  }
}
