import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ipc/json_rpc_client.dart';
import '../platform/notification_route.dart';
import '../../constants.dart';

class ClipboardSyncCoordinator {
  final JsonRpcRiftClient client;
  final void Function({
    required String title,
    required String body,
    String? route,
    Map<String, Object?>? payload,
  }) onNotifyWithRoute;

  static const _clipboardChannel =
      MethodChannel('com.biennvops.rift/clipboard');

  StreamSubscription<Map<String, dynamic>>? _clipboardOfferSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardExpiredSub;

  final List<Map<String, dynamic>> _pendingExternalClipboardPayloads =
      <Map<String, dynamic>>[];
  String? _lastExternalClipboardFingerprint;
  DateTime? _lastExternalClipboardAt;
  static const Duration _externalClipboardDuplicateWindow =
      Duration(milliseconds: 500);

  bool _clipboardServiceStarted = false;

  ClipboardSyncCoordinator({
    required this.client,
    required this.onNotifyWithRoute,
  });

  void init() {
    _bindClipboardChannel();
  }

  void bindIpcEvents() {
    _clipboardOfferSub = client.onClipboardOffer.listen((event) {
      final contentType = event['contentType']?.toString() ?? '';
      final offerId = event['offerId']?.toString();
      final sourceDeviceId =
          event['sourceDeviceId']?.toString() ?? 'trusted device';
      final isImage = contentType.startsWith('image/');
      final clipboardTitle = isImage ? 'Image received' : 'Text received';
      final clipboardBody = isImage
          ? 'Image clipboard synced from $sourceDeviceId.'
          : 'Text clipboard synced from $sourceDeviceId.';

      if (offerId == null) return;

      if ((contentType == 'text/plain' ||
              contentType == 'clipboard' ||
              contentType == 'image/png') &&
          Platform.isAndroid) {
        unawaited(() async {
          try {
            final result = await client.fetchClipboardContent(offerId);
            final contentBase64 = result['contentBase64'] as String?;
            if (contentBase64 == null) {
              return;
            }

            if (contentType == 'text/plain' || contentType == 'clipboard') {
              final bytes = base64.decode(contentBase64);
              final text = utf8.decode(bytes);
              await Clipboard.setData(ClipboardData(text: text));
            } else {
              await applyAndroidClipboardPayload(
                contentType: contentType,
                contentBase64: contentBase64,
              );
            }
            if (await _clipboardNotificationsEnabled()) {
              onNotifyWithRoute(
                title: clipboardTitle,
                body: clipboardBody,
                route: NotificationRoute.historyClipboard,
              );
            }
          } catch (e) {
            debugPrint('Auto-fetch clipboard failed: $e');
          }
        }());
      } else {
        unawaited(() async {
          if (await _clipboardNotificationsEnabled()) {
            onNotifyWithRoute(
              title: clipboardTitle,
              body: clipboardBody,
              route: NotificationRoute.historyClipboard,
            );
          }
        }());
      }
    });

    _clipboardExpiredSub = client.onClipboardExpired.listen((event) {});
  }

  void dispose() {
    _clipboardOfferSub?.cancel();
    _clipboardExpiredSub?.cancel();
    if (Platform.isAndroid && _clipboardServiceStarted) {
      _clipboardChannel.invokeMethod('stopService').catchError((Object error) {
        debugPrint('Failed to stop clipboard service: $error');
      });
    }
  }

  Future<bool> _clipboardNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppPrefs.clipboardNotificationsEnabled) ?? false;
  }

  Future<void> applyAndroidClipboardPayload({
    required String contentType,
    required String contentBase64,
  }) async {
    final applied = await _clipboardChannel.invokeMethod<bool>(
      'setClipboardContent',
      {
        'contentType': contentType,
        'contentBase64': contentBase64,
      },
    );
    if (applied != true) {
      throw StateError('Android clipboard payload was not applied');
    }
  }

  Future<void> _bindClipboardChannel() async {
    if (!Platform.isAndroid) return;

    _clipboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onClipboardChanged') {
        final args = Map<Object?, Object?>.from(
          call.arguments as Map<Object?, Object?>? ??
              const <Object?, Object?>{},
        );
        await submitExternalClipboardPayload(
          args.map((key, value) => MapEntry(key?.toString() ?? '', value)),
        );
      }
    });
    try {
      final started = await _clipboardChannel.invokeMethod('startService');
      _clipboardServiceStarted = true;
      if (started != true) {
        debugPrint('[Android Clipboard] startService returned $started');
      }
    } catch (e) {
      debugPrint('[Android Clipboard] Failed to start clipboard service: $e');
    }
  }

  String? _externalClipboardFingerprint(Map<String, dynamic> payload) {
    final contentType = payload['contentType']?.toString();
    final contentBase64 = payload['contentBase64']?.toString();
    if (contentType != null &&
        contentType.isNotEmpty &&
        contentBase64 != null &&
        contentBase64.isNotEmpty) {
      return sha256
          .convert(utf8.encode('$contentType:$contentBase64'))
          .toString();
    }

    final text = payload['text']?.toString();
    if (text != null && text.isNotEmpty) {
      return sha256.convert(utf8.encode('text/plain:$text')).toString();
    }

    return null;
  }

  bool _shouldSuppressExternalClipboardPayload(Map<String, dynamic> payload) {
    final fingerprint = _externalClipboardFingerprint(payload);
    if (fingerprint == null) {
      return false;
    }

    final now = DateTime.now();
    if (_lastExternalClipboardFingerprint == fingerprint &&
        _lastExternalClipboardAt != null &&
        now.difference(_lastExternalClipboardAt!) <=
            _externalClipboardDuplicateWindow) {
      debugPrint(
        '[Android Clipboard] Suppressed duplicate external clipboard payload.',
      );
      return true;
    }

    _lastExternalClipboardFingerprint = fingerprint;
    _lastExternalClipboardAt = now;
    return false;
  }

  void _queuePendingExternalClipboardPayload(Map<String, dynamic> payload) {
    final fingerprint = _externalClipboardFingerprint(payload);
    if (fingerprint != null) {
      final alreadyQueued = _pendingExternalClipboardPayloads.any(
        (candidate) => _externalClipboardFingerprint(candidate) == fingerprint,
      );
      if (alreadyQueued) {
        return;
      }
    }
    _pendingExternalClipboardPayloads.add(Map<String, dynamic>.from(payload));
  }

  Future<void> submitExternalClipboardPayload(
    Map<String, dynamic> payload,
  ) async {
    if (!client.isConnected) {
      _queuePendingExternalClipboardPayload(payload);
      client.connect().catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          '[Android Clipboard] Failed to reconnect for clipboard send: $error',
        );
      });
      return;
    }

    if (_shouldSuppressExternalClipboardPayload(payload)) {
      return;
    }

    final contentType = payload['contentType']?.toString();
    final contentBase64 = payload['contentBase64']?.toString();
    final text = payload['text']?.toString();

    try {
      if (contentType != null &&
          contentType.isNotEmpty &&
          contentBase64 != null &&
          contentBase64.isNotEmpty) {
        final bytes = base64.decode(contentBase64);
        final result = await client.notifyClipboardChange(
          contentType: contentType,
          byteSize: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          contentBase64: contentBase64,
        );
        debugPrint(
          '[Android Clipboard] Forwarded $contentType to peers: '
          '${(result['broadcastTo'] as List?)?.join(', ') ?? '(none)'}',
        );
        return;
      }

      if (text != null && text.isNotEmpty) {
        final bytes = utf8.encode(text);
        final result = await client.notifyClipboardChange(
          contentType: 'text/plain',
          byteSize: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          contentBase64: base64Encode(bytes),
        );
        debugPrint(
          '[Android Clipboard] Forwarded text/plain to peers: '
          '${(result['broadcastTo'] as List?)?.join(', ') ?? '(none)'}',
        );
      }
    } catch (error) {
      debugPrint(
          '[Android Clipboard] Failed to submit external payload: $error');
    }
  }

  Future<void> flushPendingExternalClipboardPayloads() async {
    if (_pendingExternalClipboardPayloads.isEmpty) {
      return;
    }

    final queued = List<Map<String, dynamic>>.from(
      _pendingExternalClipboardPayloads,
    );
    _pendingExternalClipboardPayloads.clear();
    for (final payload in queued) {
      await submitExternalClipboardPayload(payload);
    }
  }
}
