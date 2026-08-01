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
typedef ClipboardContentReader = Future<ClipboardContentPayload?> Function();
typedef ClipboardContentWriter = Future<void> Function(
  ClipboardContentPayload payload,
);

class ClipboardContentPayload {
  ClipboardContentPayload({
    required this.contentType,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes);

  factory ClipboardContentPayload.text(String text) {
    return ClipboardContentPayload(
      contentType: DesktopClipboardManager.textPlainContentType,
      bytes: Uint8List.fromList(utf8.encode(text)),
    );
  }

  final String contentType;
  final Uint8List bytes;

  int get byteSize => bytes.length;
  String get sha256Hex => sha256.convert(bytes).toString();
  String get contentBase64 => base64Encode(bytes);
}

class DesktopClipboardManager extends ChangeNotifier {
  DesktopClipboardManager(
    this._client, {
    Stream<Object?>? clipboardChanges,
    ClipboardTextReader? readClipboardText,
    ClipboardTextWriter? writeClipboardText,
    ClipboardContentReader? readClipboardContent,
    ClipboardContentWriter? writeClipboardContent,
    Set<String>? supportedContentTypes,
  })  : _readClipboardContent = readClipboardContent ??
            _contentReaderFromTextReader(
              readClipboardText ?? _defaultReadClipboardText,
            ),
        _writeClipboardContent = writeClipboardContent ??
            _contentWriterFromTextWriter(
              writeClipboardText ?? _defaultWriteClipboardText,
            ),
        _supportedContentTypes = Set<String>.unmodifiable(
          supportedContentTypes ?? const <String>{textPlainContentType},
        ),
        _clipboardChanges = clipboardChanges ??
            _defaultClipboardChanges(
              readClipboardContent ??
                  _contentReaderFromTextReader(
                    readClipboardText ?? _defaultReadClipboardText,
                  ),
            );

  static Stream<Object?> _defaultClipboardChanges(
      ClipboardContentReader reader) {
    if (Platform.isWindows) {
      return const EventChannel(_clipboardEventsChannelName)
          .receiveBroadcastStream();
    } else if (Platform.isLinux) {
      return nativeClipboardChangesWithPollingFallbackForTesting(
        const EventChannel(_clipboardEventsChannelName)
            .receiveBroadcastStream(),
        reader,
      );
    } else if (Platform.isMacOS) {
      return _pollClipboard(reader);
    }
    return const Stream.empty();
  }

  @visibleForTesting
  static Stream<Object?> nativeClipboardChangesWithPollingFallbackForTesting(
    Stream<Object?> nativeChanges,
    ClipboardContentReader reader,
  ) {
    late StreamController<Object?> controller;
    StreamSubscription<Object?>? nativeSubscription;
    StreamSubscription<Object?>? pollingSubscription;
    var fallbackStarted = false;

    void startPollingFallback() {
      if (fallbackStarted) {
        return;
      }
      fallbackStarted = true;
      pollingSubscription = _pollClipboard(reader).listen(
        controller.add,
        onError: controller.addError,
      );
    }

    controller = StreamController<Object?>.broadcast(
      onListen: () {
        nativeSubscription = nativeChanges.listen(
          controller.add,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              'Native Linux clipboard events unavailable; using polling: $error',
            );
            unawaited(nativeSubscription?.cancel());
            startPollingFallback();
          },
          onDone: startPollingFallback,
        );
      },
      onCancel: () async {
        await nativeSubscription?.cancel();
        await pollingSubscription?.cancel();
      },
    );

    return controller.stream;
  }

  static Stream<Object?> _pollClipboard(ClipboardContentReader reader) {
    late StreamController<Object?> controller;
    Timer? timer;
    String? lastFingerprint;

    void tick() async {
      try {
        final payload = await reader();
        final fingerprint = _clipboardFingerprint(payload);
        if (fingerprint == null) {
          lastFingerprint = null;
          return;
        }
        if (fingerprint != lastFingerprint) {
          lastFingerprint = fingerprint;
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
          final currentPayload = await reader();
          final currentFingerprint = _clipboardFingerprint(currentPayload);
          if (lastFingerprint != null &&
              currentFingerprint != lastFingerprint) {
            lastFingerprint = currentFingerprint;
            controller.add(null);
          }
          lastFingerprint ??= currentFingerprint;
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
  static Stream<Object?> pollClipboardForTesting(
          ClipboardContentReader reader) =>
      _pollClipboard(reader);

  static const String _clipboardEventsChannelName =
      'rift/desktop/clipboard_events';
  static const String textPlainContentType = 'text/plain';
  static const Duration _echoSuppressionWindow = Duration(seconds: 1);

  final JsonRpcRiftClient _client;
  final Stream<Object?> _clipboardChanges;
  final ClipboardContentReader _readClipboardContent;
  final ClipboardContentWriter _writeClipboardContent;
  final Set<String> _supportedContentTypes;
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

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
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

  @override
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
    super.dispose();
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

    final payload = await _readClipboardContent();
    if (payload == null) {
      return;
    }

    await handleExternalClipboardContent(payload);
  }

  Future<void> handleExternalClipboardText(String text) async {
    await handleExternalClipboardContent(ClipboardContentPayload.text(text));
  }

  Future<void> handleExternalClipboardContent(
    ClipboardContentPayload payload,
  ) async {
    if (_isDisposed || !_client.isConnected) {
      return;
    }

    if (_consumeSuppressedLocalHash(payload.sha256Hex)) {
      _log.fine('Suppressed clipboard echo for hash ${payload.sha256Hex}.');
      return;
    }

    final startedAt = DateTime.now();
    try {
      await _client.notifyClipboardChange(
        contentType: payload.contentType,
        byteSize: payload.byteSize,
        sha256: payload.sha256Hex,
        contentBase64: payload.contentBase64,
      );
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      _log.info(
        'Sent ${payload.contentType} clipboard payload '
        '(${payload.byteSize} bytes) in ${elapsedMs}ms.',
      );
      _emitStatus(_sentStatusForContentType(payload.contentType));
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to send ${payload.contentType} clipboard payload via IPC.',
        error,
        stackTrace,
      );
      _emitStatus('Clipboard sync unavailable.');
    }
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
      final result =
          await _client.listClipboardOffers() as Map<dynamic, dynamic>;
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
    final normalized = Map<String, dynamic>.from(offer);
    if (DateTime.tryParse(normalized['expiresAt']?.toString() ?? '') == null) {
      final expiresInMs = (normalized['expiresInMs'] as num?)?.toInt();
      if (expiresInMs != null && expiresInMs > 0) {
        normalized['expiresAt'] = DateTime.now()
            .toUtc()
            .add(Duration(milliseconds: expiresInMs))
            .toIso8601String();
      }
    }
    _activeOffers[offerId] = normalized;
    notifyListeners();
  }

  void _removeOfferState(String offerId) {
    if (_activeOffers.remove(offerId) != null) {
      _handledOfferIds.remove(offerId);
      notifyListeners();
    } else {
      _handledOfferIds.remove(offerId);
    }
  }

  Future<void> _maybeFetchAndApplyOffer(Map<String, dynamic> offer) async {
    final offerId = offer['offerId']?.toString();
    if (offerId == null ||
        offerId.isEmpty ||
        _handledOfferIds.contains(offerId)) {
      return;
    }

    final contentType = offer['contentType']?.toString() ?? '';
    if (!_supportedContentTypes.contains(contentType)) {
      _log.fine(
          'Ignoring unsupported clipboard content type: ${offer['contentType']}.');
      return;
    }

    _handledOfferIds.add(offerId);
    await fetchAndApplyOffer(offerId);
  }

  Future<ClipboardContentPayload?> fetchOfferPayload(String offerId) async {
    final offer = _activeOffers[offerId];
    if (offer == null) {
      return null;
    }
    final contentType = offer['contentType']?.toString() ?? '';
    try {
      final result =
          await _client.fetchClipboardContent(offerId) as Map<dynamic, dynamic>;
      if (_isDisposed) return null;
      final canonical = Map<String, dynamic>.from(result);
      if (canonical['verified'] != true) {
        _log.warning('Clipboard fetch for $offerId was not verified.');
        return null;
      }
      final contentBase64 = canonical['contentBase64']?.toString();
      if (contentBase64 == null) {
        _log.warning(
            'Clipboard fetch for $offerId returned an incomplete payload.');
        return null;
      }
      final bytes = Uint8List.fromList(base64Decode(contentBase64));
      return ClipboardContentPayload(contentType: contentType, bytes: bytes);
    } catch (error, stackTrace) {
      if (error.toString().contains('-32009') ||
          error.toString().toLowerCase().contains('not found') ||
          error.toString().toLowerCase().contains('expired')) {
        _removeOfferState(offerId);
      }
      _log.warning(
          'Failed to fetch offer payload $offerId.', error, stackTrace);
      return null;
    }
  }

  Future<bool> fetchAndApplyOffer(String offerId) async {
    _emitStatus('Fetching clipboard from peer...');
    final startedAt = DateTime.now();
    final payload = await fetchOfferPayload(offerId);
    if (payload == null || _isDisposed) {
      _handledOfferIds.remove(offerId);
      _emitStatus('Clipboard fetch failed');
      return false;
    }

    try {
      if (_supportedContentTypes.contains(payload.contentType)) {
        await _writeClipboardContent(payload);
      } else if (payload.contentType == textPlainContentType ||
          payload.contentType == 'clipboard') {
        final text = utf8.decode(payload.bytes);
        await Clipboard.setData(ClipboardData(text: text));
      } else {
        _log.warning(
            'Unsupported content type for clipboard copy: ${payload.contentType}');
        _emitStatus('Unsupported clipboard format');
        return false;
      }

      if (_isDisposed) {
        return false;
      }
      _enqueueSuppressedLocalHash(payload.sha256Hex);
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      _log.info(
        'Fetched and applied ${payload.contentType} clipboard payload '
        '(${payload.bytes.length} bytes) in ${elapsedMs}ms.',
      );
      _emitStatus(_receivedStatusForContentType(payload.contentType));
      return true;
    } catch (error, stackTrace) {
      _handledOfferIds.remove(offerId);
      if (error.toString().contains('-32009') ||
          error.toString().toLowerCase().contains('not found') ||
          error.toString().toLowerCase().contains('expired')) {
        _removeOfferState(offerId);
      }
      _log.warning(
          'Failed to apply clipboard offer $offerId.', error, stackTrace);
      _emitStatus('Clipboard fetch failed');
      return false;
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

  static ClipboardContentReader _contentReaderFromTextReader(
    ClipboardTextReader reader,
  ) {
    return () async {
      final text = await reader();
      if (text == null) {
        return null;
      }
      return ClipboardContentPayload.text(text);
    };
  }

  static ClipboardContentWriter _contentWriterFromTextWriter(
    ClipboardTextWriter writer,
  ) {
    return (payload) async {
      if (payload.contentType != textPlainContentType) {
        throw UnsupportedError(
          'Clipboard content type ${payload.contentType} is not supported by the default writer.',
        );
      }

      await writer(utf8.decode(payload.bytes));
    };
  }

  static String? _clipboardFingerprint(ClipboardContentPayload? payload) {
    if (payload == null) {
      return null;
    }
    return '${payload.contentType}:${payload.byteSize}:${payload.sha256Hex}';
  }

  static String _sentStatusForContentType(String contentType) {
    return contentType == textPlainContentType
        ? 'Clipboard sent to peers'
        : 'Clipboard content sent to peers';
  }

  static String _receivedStatusForContentType(String contentType) {
    return contentType == textPlainContentType
        ? 'Clipboard received from peer'
        : 'Clipboard content received from peer';
  }

  static Future<String?> _defaultReadClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  static Future<void> _defaultWriteClipboardText(String text) {
    return Clipboard.setData(ClipboardData(text: text));
  }
}
