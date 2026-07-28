import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../ipc/json_rpc_client.dart';
import 'desktop_clipboard_manager.dart';

const _desktopClipboardChannel = MethodChannel('rift/desktop/clipboard');
String? _lastDesktopClipboardReadFingerprint;

String _desktopClipboardFingerprint(String contentType, Uint8List bytes) {
  final byteDigest = base64Encode(bytes);
  return '$contentType:${bytes.length}:$byteDigest';
}

Future<ClipboardContentPayload?> _readDesktopClipboardContent() async {
  final raw = await _desktopClipboardChannel.invokeMethod<Object>(
    'getClipboardContent',
  );
  if (raw is! Map) {
    if (_lastDesktopClipboardReadFingerprint != 'empty') {
      _lastDesktopClipboardReadFingerprint = 'empty';
      debugPrint(
          '[Desktop Clipboard] No clipboard payload returned by native bridge.');
    }
    return null;
  }

  final contentType = raw['contentType'] as String?;
  final bytes = raw['bytes'];
  if (contentType == null || bytes is! Uint8List) {
    debugPrint(
      '[Desktop Clipboard] Native bridge returned an incomplete payload: '
      'contentType=$contentType bytesType=${bytes.runtimeType}',
    );
    return null;
  }

  final fingerprint = _desktopClipboardFingerprint(contentType, bytes);
  if (_lastDesktopClipboardReadFingerprint != fingerprint) {
    _lastDesktopClipboardReadFingerprint = fingerprint;
    debugPrint(
      '[Desktop Clipboard] Read native payload type=$contentType bytes=${bytes.length}',
    );
  }

  return ClipboardContentPayload(
    contentType: contentType,
    bytes: bytes,
  );
}

Future<void> _writeDesktopClipboardContent(
  ClipboardContentPayload payload,
) async {
  final applied = await _desktopClipboardChannel.invokeMethod<bool>(
    'setClipboardContent',
    {
      'contentType': payload.contentType,
      'bytes': payload.bytes,
    },
  );
  if (applied != true) {
    throw StateError(
      'Desktop clipboard payload was not applied for ${payload.contentType}.',
    );
  }
  debugPrint(
    '[Desktop Clipboard] Applied native payload type=${payload.contentType} bytes=${payload.byteSize}',
  );
}

DesktopClipboardManager createDesktopClipboardManager(
    JsonRpcRiftClient client) {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return DesktopClipboardManager(
      client,
      readClipboardContent: _readDesktopClipboardContent,
      writeClipboardContent: _writeDesktopClipboardContent,
      supportedContentTypes: const <String>{'text/plain', 'image/png'},
    );
  }

  return DesktopClipboardManager(client);
}
