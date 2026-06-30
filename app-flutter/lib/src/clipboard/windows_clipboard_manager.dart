import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../ipc/json_rpc_client.dart';

typedef ClipboardTextReader = Future<String?> Function();
typedef ClipboardTextWriter = Future<void> Function(String text);

class WindowsClipboardManager {
  WindowsClipboardManager(
    this._client, {
    Stream<Object?>? clipboardChanges,
    ClipboardTextReader? readClipboardText,
    ClipboardTextWriter? writeClipboardText,
  })  : _clipboardChanges = clipboardChanges ??
            const EventChannel(_clipboardEventsChannelName)
                .receiveBroadcastStream(),
        _readClipboardText = readClipboardText ?? _defaultReadClipboardText,
        _writeClipboardText = writeClipboardText ?? _defaultWriteClipboardText;

  static const String _clipboardEventsChannelName =
      'rift/windows/clipboard_events';
  static const String _textPlainContentType = 'text/plain';

  final JsonRpcRiftClient _client;
  final Stream<Object?> _clipboardChanges;
  final ClipboardTextReader _readClipboardText;
  final ClipboardTextWriter _writeClipboardText;
  final Logger _log = Logger('WindowsClipboardManager');
  final Map<String, Map<String, dynamic>> _activeOffers = {};
  final Set<String> _handledOfferIds = <String>{};

  StreamSubscription<Object?>? _clipboardChangeSub;
  StreamSubscription<Map<String, dynamic>>? _offerSub;
  StreamSubscription<Map<String, dynamic>>? _expiredSub;
  StreamSubscription<bool>? _connectionSub;
  String? _suppressedNextLocalSha256;
  bool _started = false;
  bool _resyncInFlight = false;

  UnmodifiableMapView<String, Map<String, dynamic>> get activeOffers =>
      UnmodifiableMapView(_activeOffers);

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;

    _offerSub = _client.onClipboardOffer.listen(_handleClipboardOffer);
    _expiredSub = _client.onClipboardExpired.listen(_handleClipboardExpired);
    _connectionSub = _client.onConnectionChanged.listen((isConnected) {
      if (isConnected) {
        unawaited(_resyncOffers());
      }
    });
    _clipboardChangeSub = _clipboardChanges.listen((_) {
      unawaited(_handleLocalClipboardChanged());
    });

    if (_client.isConnected) {
      await _resyncOffers();
    }
  }

  Future<void> dispose() async {
    await _clipboardChangeSub?.cancel();
    await _offerSub?.cancel();
    await _expiredSub?.cancel();
    await _connectionSub?.cancel();
  }

  Future<void> _handleLocalClipboardChanged() async {
    if (!_client.isConnected) {
      return;
    }

    final text = await _readClipboardText();
    if (text == null) {
      return;
    }

    final payload = _encodeClipboardText(text);
    if (_suppressedNextLocalSha256 == payload.sha256) {
      _suppressedNextLocalSha256 = null;
      _log.fine('Suppressed clipboard echo for hash ${payload.sha256}.');
      return;
    }

    await _client.notifyClipboardChange(
      contentType: _textPlainContentType,
      byteSize: payload.byteSize,
      sha256: payload.sha256,
      contentBase64: payload.contentBase64,
    );
  }

  Future<void> _resyncOffers() async {
    if (!_client.isConnected || _resyncInFlight) {
      return;
    }

    _resyncInFlight = true;
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
      _activeOffers.removeWhere((offerId, _) => !nextOfferIds.contains(offerId));

      for (final offer in offers) {
        _upsertOffer(offer);
        await _maybeFetchAndApplyOffer(offer);
      }
    } catch (error, stackTrace) {
      _log.warning('Clipboard offer resync failed.', error, stackTrace);
    } finally {
      _resyncInFlight = false;
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
    _activeOffers.remove(offerId);
  }

  void _upsertOffer(Map<String, dynamic> offer) {
    final offerId = offer['offerId']?.toString();
    if (offerId == null || offerId.isEmpty) {
      return;
    }
    _activeOffers[offerId] = Map<String, dynamic>.from(offer);
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
      final result =
          await _client.fetchClipboardContent(offerId) as Map<dynamic, dynamic>;
      final canonical = Map<String, dynamic>.from(result);
      if (canonical['verified'] != true) {
        _log.warning('Clipboard fetch for $offerId was not verified.');
        return;
      }

      final contentBase64 = canonical['contentBase64']?.toString();
      final sha256 = canonical['sha256']?.toString();
      if (contentBase64 == null || sha256 == null) {
        _log.warning('Clipboard fetch for $offerId returned an incomplete payload.');
        return;
      }

      final bytes = base64Decode(contentBase64);
      final text = utf8.decode(bytes);
      _suppressedNextLocalSha256 = sha256;
      await _writeClipboardText(text);
    } catch (error, stackTrace) {
      _handledOfferIds.remove(offerId);
      _log.warning('Failed to fetch/apply clipboard offer $offerId.', error, stackTrace);
    }
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
