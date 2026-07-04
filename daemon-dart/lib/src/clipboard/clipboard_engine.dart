import 'dart:async';
import 'clipboard_models.dart';

class ClipboardEngine {
  // Store active offers: offerId -> ClipboardOffer
  final Map<String, ClipboardOffer> _activeOffers = {};
  
  // Track absolute expiry time
  final Map<String, DateTime> _offerExpiresAt = {};

  // Tag which offers are local (our own) vs. remote (from peers)
  final Set<String> _localOfferIds = {};

  // In-memory content store for local offers (offerId -> base64 content)
  final Map<String, String> _localContent = {};

  // Track high-water mark of offerSequence per peer (deviceId -> highest sequence)
  final Map<String, int> _peerOfferSequences = {};

  // Track timers for expiry
  final Map<String, Timer> _expiryTimers = {};

  // Stream controller for when an offer expires
  final _offerExpiredController = StreamController<String>.broadcast();
  Stream<String> get onOfferExpired => _offerExpiredController.stream;

  // Stream controller for when a new valid offer is added (useful for IPC/UI)
  final _offerAddedController = StreamController<ClipboardOffer>.broadcast();
  Stream<ClipboardOffer> get onOfferAdded => _offerAddedController.stream;

  // Track our own sequence number
  int _localSequence = 0;

  void dispose() {
    for (var timer in _expiryTimers.values) {
      timer.cancel();
    }
    _expiryTimers.clear();
    _offerExpiresAt.clear();
    _localOfferIds.clear();
    _localContent.clear();
    _offerExpiredController.close();
    _offerAddedController.close();
  }

  /// Process an incoming offer from a peer.
  /// Returns true if accepted, false if rejected (e.g. replay/out-of-order).
  bool processIncomingOffer(ClipboardOffer offer) {
    // 1. Sequence check (Monotonic increasing)
    final currentHighWaterMark = _peerOfferSequences[offer.sourceDeviceId] ?? -1;
    if (offer.offerSequence <= currentHighWaterMark) {
      // Replay or out-of-order, reject it.
      return false;
    }
    
    // Update high-water mark
    _peerOfferSequences[offer.sourceDeviceId] = offer.offerSequence;

    // 2. Add to active offers
    _activeOffers[offer.offerId] = offer;
    _offerExpiresAt[offer.offerId] = DateTime.now().toUtc().add(Duration(milliseconds: offer.expiresInMs));

    // 3. Setup expiry timer
    _setupExpiryTimer(offer);

    // Notify listeners
    _offerAddedController.add(offer);

    return true;
  }

  /// Generate an offer from local content (e.g. user copied text).
  ClipboardOffer createLocalOffer({
    required String offerId,
    required String contentType,
    required int byteSize,
    required String sha256,
    required int expiresInMs,
    required String localDeviceId,
    required String contentBase64,
  }) {
    _localSequence++;
    
    final offer = ClipboardOffer(
      offerId: offerId,
      contentType: contentType,
      byteSize: byteSize,
      sha256: sha256,
      expiresInMs: expiresInMs,
      sourceDeviceId: localDeviceId,
      requiredCapability: 'clipboard.offer_fetch',
      offerSequence: _localSequence,
    );

    // Add to active offers and tag as local
    _activeOffers[offer.offerId] = offer;
    _localOfferIds.add(offer.offerId);
    _localContent[offer.offerId] = contentBase64;
    _offerExpiresAt[offer.offerId] = DateTime.now().toUtc().add(Duration(milliseconds: offer.expiresInMs));
    _setupExpiryTimer(offer);

    return offer;
  }

  void _setupExpiryTimer(ClipboardOffer offer) {
    // Cancel any existing timer for this offerId just in case
    _expiryTimers[offer.offerId]?.cancel();

    _expiryTimers[offer.offerId] = Timer(Duration(milliseconds: offer.expiresInMs), () {
      _handleOfferExpiry(offer.offerId);
    });
  }

  void _handleOfferExpiry(String offerId) {
    _activeOffers.remove(offerId);
    _offerExpiresAt.remove(offerId);
    _localOfferIds.remove(offerId);
    _localContent.remove(offerId);
    _expiryTimers.remove(offerId);
    _offerExpiredController.add(offerId);
  }

  ClipboardOffer? getOffer(String offerId) {
    return _activeOffers[offerId];
  }

  List<ClipboardOffer> getAllOffers() {
    return _activeOffers.values.toList();
  }

  /// Returns only offers received from peers (not our own local offers).
  List<ClipboardOffer> getIncomingOffers() {
    return _activeOffers.values
        .where((o) => !_localOfferIds.contains(o.offerId))
        .toList();
  }

  /// Returns the base64 content for a local offer (null if not local or expired).
  String? getLocalContent(String offerId) {
    return _localContent[offerId];
  }

  bool isLocalOffer(String offerId) {
    return _localOfferIds.contains(offerId);
  }

  DateTime? getOfferExpiresAt(String offerId) {
    return _offerExpiresAt[offerId];
  }
}
