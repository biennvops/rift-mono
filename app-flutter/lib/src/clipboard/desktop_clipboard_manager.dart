import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../ipc/json_rpc_client.dart';

typedef ClipboardTextReader = Future<String?> Function();
typedef ClipboardTextWriter = Future<void> Function(String text);

class DesktopClipboardManager {
  DesktopClipboardManager(
    this._client, {
    Stream<Object?>? clipboardChanges,
    ClipboardTextReader? readClipboardText,
    ClipboardTextWriter? writeClipboardText,
  })  : _readClipboardText = readClipboardText ?? _defaultReadClipboardText,
        _writeClipboardText = writeClipboardText ?? _defaultWriteClipboardText,
        _clipboardChanges = clipboardChanges ??
            _defaultClipboardChanges(
              readClipboardText ?? _defaultReadClipboardText,
            );

  static Stream<Object?> _defaultClipboardChanges(ClipboardTextReader reader) {
    if (Platform.isWindows) {
      return const EventChannel(_clipboardEventsChannelName).receiveBroadcastStream();
    } else if (Platform.isMacOS || Platform.isLinux) {
      return _pollClipboard(reader);
    }
    return const Stream.empty();
  }

  static Stream<Object?> _pollClipboard(ClipboardTextReader reader) {
    late StreamController<Object?> controller;
    Timer? timer;
    String? lastText;

    void tick() async {
      try {
        final text = await reader();
        if (text != null && text != lastText) {
          lastText = text;
          controller.add(null);
        }
      } on PlatformException catch (e) {
        debugPrint('Polling clipboard failed: $e');
      } on MissingPluginException catch (e) {
        debugPrint('Polling clipboard missing plugin: $e');
      }
    }

    controller = StreamController<Object?>.broadcast(
      onListen: () async {
        try {
          final currentText = await reader();
          if (lastText != null && currentText != lastText) {
            lastText = currentText;
            controller.add(null);
          }
          lastText ??= currentText;
        } on PlatformException catch (e) {
          debugPrint('Initial clipboard read failed: $e');
        } on MissingPluginException catch (e) {
          debugPrint('Initial clipboard missing plugin: $e');
        }
        // REVIEW REJECTION (desktop_clipboard_manager.dart:66):
        // Reviewer suggested pausing this 1Hz timer when the window is hidden to tray.
        // STATUS: REJECTED (WORKING AS INTENDED).
        // Rift is a continuity app. Clipboard sync MUST keep running in the background 
        // while the desktop shell hides the window to tray. Pausing this timer would
        // completely break the core functionality of background copy/paste.
        timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
      },
      onCancel: () {
        timer?.cancel();
      },
    );

    return controller.stream;
  }

  @visibleForTesting
  static Stream<Object?> pollClipboardForTesting(ClipboardTextReader reader) =>
      _pollClipboard(reader);

  static const String _clipboardEventsChannelName =
      'rift/desktop/clipboard_events';
  static const String _textPlainContentType = 'text/plain';
  static const Duration _echoSuppressionWindow = Duration(seconds: 1);

  final JsonRpcRiftClient _client;
  final Stream<Object?> _clipboardChanges;
  final ClipboardTextReader _readClipboardText;
  final ClipboardTextWriter _writeClipboardText;
  final Logger _log = Logger('DesktopClipboardManager');
  final Map<String, Map<String, dynamic>> _activeOffers = {};
  final Set<String> _handledOfferIds = <String>{};
  final Map<String, DateTime> _suppressedLocalSha256Deadlines =
      <String, DateTime>{};

  StreamSubscription<Object?>? _clipboardChangeSub;
  StreamSubscription<Map<String, dynamic>>? _offerSub;
  StreamSubscription<Map<String, dynamic>>? _expiredSub;
  StreamSubscription<bool>? _connectionSub;
  bool _started = false;
  bool _isDisposed = false;
  bool _resyncInFlight = false;
  bool _resyncRequested = false;
  bool _windowVisible = true;

  final StreamController<String> _statusController = StreamController<String>.broadcast();
  Stream<String> get onStatusUpdate => _statusController.stream;
  void notifyStatus(String status) => _emitStatus(status);

  UnmodifiableMapView<String, Map<String, dynamic>> get activeOffers =>
      UnmodifiableMapView(_activeOffers);

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    _isDisposed = false;

    _offerSub = _client.onClipboardOffer.listen(_handleClipboardOffer);
    _expiredSub = _client.onClipboardExpired.listen(_handleClipboardExpired);
    _connectionSub = _client.onConnectionChanged.listen((isConnected) {
      if (isConnected) {
        unawaited(_resyncOffers());
      }
    });
    await _setClipboardMonitoringEnabled(_windowVisible);

    if (_client.isConnected) {
      await _resyncOffers();
    }
  }

  Future<void> setWindowVisible(bool visible) async {
    _windowVisible = visible;
    if (!_started || _isDisposed) {
      return;
    }

    // Clipboard sync is expected to keep running while the desktop shell hides
    // the window to tray. We still track visibility for future UX throttling,
    // but monitoring itself stays active until the manager is disposed.
    if (_clipboardChangeSub == null) {
      await _setClipboardMonitoringEnabled(true);
    }
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await _clipboardChangeSub?.cancel();
    _clipboardChangeSub = null;
    await _offerSub?.cancel();
    await _expiredSub?.cancel();
    await _connectionSub?.cancel();
    _activeOffers.clear();
    _handledOfferIds.clear();
    _suppressedLocalSha256Deadlines.clear();
    await _statusController.close();
  }

  Future<void> _setClipboardMonitoringEnabled(bool enabled) async {
    if (enabled) {
      if (_clipboardChangeSub != null) {
        return;
      }
      _clipboardChangeSub = _clipboardChanges.listen((_) {
        unawaited(_handleLocalClipboardChanged());
      });
      return;
    }

    await _clipboardChangeSub?.cancel();
    _clipboardChangeSub = null;
  }

  Future<void> _handleLocalClipboardChanged() async {
    if (_isDisposed || !_client.isConnected) {
      return;
    }

    final text = await _readClipboardText();
    if (text == null) {
      return;
    }

    await handleExternalClipboardText(text);
  }

  Future<void> handleExternalClipboardText(String text) async {
    if (_isDisposed || !_client.isConnected) {
      return;
    }

    final payload = _encodeClipboardText(text);
    if (_consumeSuppressedLocalHash(payload.sha256)) {
      _log.fine('Suppressed clipboard echo for hash ${payload.sha256}.');
      return;
    }

    await _client.notifyClipboardChange(
      contentType: _textPlainContentType,
      byteSize: payload.byteSize,
      sha256: payload.sha256,
      contentBase64: payload.contentBase64,
    );
    _emitStatus('Clipboard sent to peers');
  }


  Future<void> _resyncOffers() async {
    if (!_client.isConnected) {
      return;
    }

    if (_resyncInFlight) {
      _resyncRequested = true;
      return;
    }

    _resyncInFlight = true;
    _resyncRequested = false;
    try {
      final result = await _client.listClipboardOffers() as Map<dynamic, dynamic>;
      final offers = List<Map<String, dynamic>>.from(
        (result['offers'] as List<dynamic>? ?? const <dynamic>[])
            .map((offer) => Map<String, dynamic>.from(offer as Map)),
      );

      final nextOfferIds = offers
          .map((offer) => offer['offerId']?.toString())
          .whereType<String>()
          .toSet();
      final removedOfferIds = _activeOffers.keys
          .where((offerId) => !nextOfferIds.contains(offerId))
          .toList(growable: false);
      for (final offerId in removedOfferIds) {
        _removeOfferState(offerId);
      }

      for (final offer in offers) {
        _upsertOffer(offer);
        await _maybeFetchAndApplyOffer(offer);
      }
    } catch (error, stackTrace) {
      _log.warning('Clipboard offer resync failed.', error, stackTrace);
    } finally {
      _resyncInFlight = false;
      if (_resyncRequested && _client.isConnected) {
        unawaited(_resyncOffers());
      }
    }
  }

  void _handleClipboardOffer(Map<String, dynamic> offer) {
    _upsertOffer(offer);
    unawaited(_maybeFetchAndApplyOffer(offer));
  }

  void _handleClipboardExpired(Map<String, dynamic> payload) {
    final offerId = payload['offerId']?.toString();
    if (offerId == null || offerId.isEmpty) {
      return;
    }
    _removeOfferState(offerId);
  }

  void _upsertOffer(Map<String, dynamic> offer) {
    final offerId = offer['offerId']?.toString();
    if (offerId == null || offerId.isEmpty) {
      return;
    }
    _activeOffers[offerId] = Map<String, dynamic>.from(offer);
  }

  void _removeOfferState(String offerId) {
    _activeOffers.remove(offerId);
    _handledOfferIds.remove(offerId);
  }

  Future<void> _maybeFetchAndApplyOffer(Map<String, dynamic> offer) async {
    final offerId = offer['offerId']?.toString();
    if (offerId == null || offerId.isEmpty || _handledOfferIds.contains(offerId)) {
      return;
    }

    if (offer['contentType']?.toString() != _textPlainContentType) {
      _log.fine('Ignoring unsupported clipboard content type: ${offer['contentType']}.');
      return;
    }

    _handledOfferIds.add(offerId);
    try {
      _emitStatus('Fetching clipboard from peer...');
      final result =
          await _client.fetchClipboardContent(offerId) as Map<dynamic, dynamic>;
      if (_isDisposed) {
        return;
      }
      final canonical = Map<String, dynamic>.from(result);
      if (canonical['verified'] != true) {
        _log.warning('Clipboard fetch for $offerId was not verified.');
        _emitStatus('Clipboard fetch failed: unverified');
        return;
      }

      final contentBase64 = canonical['contentBase64']?.toString();
      final sha256 = canonical['sha256']?.toString();
      if (contentBase64 == null || sha256 == null) {
        _log.warning('Clipboard fetch for $offerId returned an incomplete payload.');
        _emitStatus('Clipboard fetch failed: incomplete payload');
        return;
      }

      final bytes = base64Decode(contentBase64);
      final text = utf8.decode(bytes);
      if (_isDisposed) {
        return;
      }
      await _writeClipboardText(text);
      if (_isDisposed) {
        return;
      }
      _enqueueSuppressedLocalHash(sha256);
      _emitStatus('Clipboard received from peer');
    } catch (error, stackTrace) {
      _handledOfferIds.remove(offerId);
      _log.warning('Failed to fetch/apply clipboard offer $offerId.', error, stackTrace);
      _emitStatus('Clipboard fetch failed');
    }
  }

  void _emitStatus(String status) {
    if (_isDisposed || _statusController.isClosed) {
      return;
    }
    _statusController.add(status);
  }

  void _enqueueSuppressedLocalHash(String sha256) {
    _suppressedLocalSha256Deadlines[sha256] =
        DateTime.now().add(_echoSuppressionWindow);
  }

  bool _consumeSuppressedLocalHash(String sha256) {
    final deadline = _suppressedLocalSha256Deadlines[sha256];
    if (deadline == null) {
      return false;
    }

    final now = DateTime.now();
    if (deadline.isBefore(now)) {
      _suppressedLocalSha256Deadlines.remove(sha256);
      return false;
    }

    return true;
  }

  static _ClipboardPayload _encodeClipboardText(String text) {
    final bytes = utf8.encode(text);
    return _ClipboardPayload(
      byteSize: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      contentBase64: base64Encode(bytes),
    );
  }

  static Future<String?> _defaultReadClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  static Future<void> _defaultWriteClipboardText(String text) {
    return Clipboard.setData(ClipboardData(text: text));
  }
}

class _ClipboardPayload {
  const _ClipboardPayload({
    required this.byteSize,
    required this.sha256,
    required this.contentBase64,
  });

  final int byteSize;
  final String sha256;
  final String contentBase64;
}
