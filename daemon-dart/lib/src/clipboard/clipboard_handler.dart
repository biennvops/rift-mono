import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../core/rift_log.dart';
import '../network/session_manager.dart';
import 'clipboard_engine.dart';
import 'clipboard_models.dart';

typedef ContentFetcher = Future<String?> Function(String offerId);

class ClipboardProtocolHandler {
  final SessionManager _sessionManager;
  final ClipboardEngine _engine;
  final ContentFetcher _localContentFetcher;
  final String _localDeviceId;
  
  late final StreamSubscription<ProtocolMessage> _messageSub;

  final _fetchResponseController = StreamController<ClipboardFetchResponse>.broadcast();
  Stream<ClipboardFetchResponse> get onFetchResponse => _fetchResponseController.stream;

  final _fetchRejectController = StreamController<ClipboardFetchReject>.broadcast();
  Stream<ClipboardFetchReject> get onFetchReject => _fetchRejectController.stream;

  final void Function(String peerDeviceId, String offerId)? onFetchRequestReceived;

  ClipboardProtocolHandler(
      this._sessionManager, this._engine, this._localContentFetcher, this._localDeviceId, {this.onFetchRequestReceived}) {
    _messageSub = _sessionManager.onMessage.listen(_handleMessage);
  }

  void dispose() {
    _messageSub.cancel();
    _fetchResponseController.close();
    _fetchRejectController.close();
  }

  Future<void> _handleMessage(ProtocolMessage msg) async {
    final type = msg.payload['type'] as String?;
    if (type == null || !type.startsWith('clipboard.')) return;

    try {
      // Capability & Trust checks are handled here
      _sessionManager.requireCapability(msg.peerDeviceId, 'clipboard.offer_fetch');
    } catch (e) {
      RiftLog.warn('[Clipboard] Dropping $type from ${msg.peerDeviceId}: $e');
      return;
    }

    final payload = msg.payload['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      RiftLog.warn('[Clipboard] Missing payload for $type from ${msg.peerDeviceId}');
      return;
    }

    try {
      switch (type) {
        case 'clipboard.offer':
          await _handleOffer(msg.peerDeviceId, payload);
          break;
        case 'clipboard.fetchRequest':
          await _handleFetchRequest(msg.peerDeviceId, payload);
          break;
        case 'clipboard.fetchResponse':
          await _handleFetchResponse(msg.peerDeviceId, payload);
          break;
        case 'clipboard.fetchReject':
          await _handleFetchReject(msg.peerDeviceId, payload);
          break;
        default:
          RiftLog.warn('[Clipboard] Unknown clipboard message type: $type');
      }
    } catch (e, st) {
      if (type == 'clipboard.fetchResponse') {
        RiftLog.error(
          '[Clipboard] Malformed fetchResponse',
          error: e,
          stackTrace: st,
        );
        final offerId = payload['offerId'];
        if (offerId is String && offerId.isNotEmpty) {
          _fetchRejectController.add(
            ClipboardFetchReject(
              offerId: offerId,
              failureReason: 'HashMismatch',
              message: 'Malformed fetchResponse payload',
            ),
          );
          return;
        }
      }
      RiftLog.error('[Clipboard] Error handling $type', error: e, stackTrace: st);
    }
  }

  Future<void> _handleOffer(String peerDeviceId, Map<String, dynamic> payload) async {
    final offer = ClipboardOffer.fromJson(payload);
    
    if (offer.sourceDeviceId != peerDeviceId) {
      RiftLog.error('[Clipboard] sourceDeviceId mismatch. Expected $peerDeviceId, got ${offer.sourceDeviceId}');
      return; // Reject Unauthorized silently by dropping
    }
    
    if (offer.byteSize > 32 * 1024 * 1024) { // 32 MiB
      RiftLog.warn('[Clipboard] Offer byteSize too large: ${offer.byteSize}');
      return;
    }

    final accepted = _engine.processIncomingOffer(offer);
    if (!accepted) {
      RiftLog.warn('[Clipboard] Offer rejected by engine (replay or out-of-order sequence)');
    }
  }

  Future<void> sendFetchRequest(String peerDeviceId, String offerId) async {
    final req = ClipboardFetchRequest(offerId: offerId, requestingDeviceId: _localDeviceId);
    final msg = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'clipboard.fetchRequest',
      'sourceDeviceId': _localDeviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': req.toJson(),
    };
    await _sessionManager.sendMessage(peerDeviceId, msg);
  }

  Future<void> _handleFetchRequest(String peerDeviceId, Map<String, dynamic> payload) async {
    final req = ClipboardFetchRequest.fromJson(payload);
    
    onFetchRequestReceived?.call(peerDeviceId, req.offerId);

    if (req.requestingDeviceId != peerDeviceId) {
      await _sendFetchReject(peerDeviceId, req.offerId, 'Unauthorized', 'requestingDeviceId mismatch');
      return;
    }

    final offer = _engine.getOffer(req.offerId);
    if (offer == null) {
      await _sendFetchReject(peerDeviceId, req.offerId, 'OfferExpired', 'Offer expired or does not exist');
      return;
    }

    if (!_engine.isLocalOffer(req.offerId)) {
      await _sendFetchReject(
        peerDeviceId,
        req.offerId,
        'OfferExpired',
        'Offer is not owned by this device',
      );
      return;
    }

    // Retrieve local content
    final contentBase64 = await _localContentFetcher(req.offerId);
    if (contentBase64 == null) {
      await _sendFetchReject(
        peerDeviceId,
        req.offerId,
        'OfferExpired',
        'Offer content is no longer available',
      );
      return;
    }

    final bytes = base64.decode(contentBase64);
    final hash = sha256.convert(bytes).toString();

    // Verify hash matches what we offered
    if (hash != offer.sha256) {
       await _sendFetchReject(
         peerDeviceId,
         req.offerId,
         'HashMismatch',
         'Local content hash mismatch',
       );
       return;
    }

    final resp = ClipboardFetchResponse(
      offerId: req.offerId,
      contentBase64: contentBase64,
      byteSize: bytes.length,
      sha256: hash,
    );

    final msg = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'clipboard.fetchResponse',
      'sourceDeviceId': _localDeviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': resp.toJson(),
    };
    await _sessionManager.sendMessage(peerDeviceId, msg);
  }

  Future<void> _handleFetchResponse(String peerDeviceId, Map<String, dynamic> payload) async {
    final resp = ClipboardFetchResponse.fromJson(payload);
    late final List<int> bytes;
    try {
      bytes = base64.decode(resp.contentBase64);
    } on FormatException {
      RiftLog.error('[Clipboard] Malformed base64 in fetchResponse');
      _fetchRejectController.add(
        ClipboardFetchReject(
          offerId: resp.offerId,
          failureReason: 'HashMismatch',
          message: 'Malformed base64 payload',
        ),
      );
      return;
    }

    if (bytes.length > 32 * 1024 * 1024) {
      RiftLog.error('[Clipboard] Payload too large in fetchResponse');
      _fetchRejectController.add(
        ClipboardFetchReject(
          offerId: resp.offerId,
          failureReason: 'HashMismatch',
          message: 'Decoded payload exceeds maximum size',
        ),
      );
      return;
    }

    if (bytes.length != resp.byteSize) {
      RiftLog.error(
        '[Clipboard] byteSize mismatch in fetchResponse: declared ${resp.byteSize}, actual ${bytes.length}',
      );
      _fetchRejectController.add(
        ClipboardFetchReject(
          offerId: resp.offerId,
          failureReason: 'HashMismatch',
          message: 'byteSize mismatch in fetchResponse',
        ),
      );
      return;
    }

    final hash = sha256.convert(bytes).toString();
    if (hash != resp.sha256) {
      RiftLog.error('[Clipboard] Hash mismatch in fetchResponse: expected ${resp.sha256}, got $hash');
      _fetchRejectController.add(
        ClipboardFetchReject(
          offerId: resp.offerId,
          failureReason: 'HashMismatch',
          message: 'Hash mismatch in fetchResponse',
        ),
      );
      return;
    }

    _fetchResponseController.add(resp);
  }

  Future<void> _handleFetchReject(String peerDeviceId, Map<String, dynamic> payload) async {
    final reject = ClipboardFetchReject.fromJson(payload);
    _fetchRejectController.add(reject);
  }

  Future<void> _sendFetchReject(String peerDeviceId, String offerId, String failureReason, String message) async {
    final reject = ClipboardFetchReject(offerId: offerId, failureReason: failureReason, message: message);
    final msg = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'clipboard.fetchReject',
      'sourceDeviceId': _localDeviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': reject.toJson(),
    };
    await _sessionManager.sendMessage(peerDeviceId, msg);
  }
}
