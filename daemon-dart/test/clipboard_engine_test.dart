import 'package:test/test.dart';
import 'package:daemon_dart/src/clipboard/clipboard_engine.dart';
import 'package:daemon_dart/src/clipboard/clipboard_models.dart';

void main() {
  group('ClipboardEngine', () {
    late ClipboardEngine engine;

    setUp(() {
      engine = ClipboardEngine();
    });

    tearDown(() {
      engine.dispose();
    });

    test('createLocalOffer increments sequence and adds to active offers', () {
      final offer = engine.createLocalOffer(
        offerId: 'offer1',
        contentType: 'text/plain',
        byteSize: 11,
        sha256: 'hash1',
        expiresInMs: 10000,
        localDeviceId: 'deviceA',
        contentBase64: 'SGVsbG8gV29ybGQ=',
      );

      expect(offer.offerSequence, 1);
      expect(engine.getAllOffers().length, 1);
      expect(engine.getOffer('offer1'), offer);

      final offer2 = engine.createLocalOffer(
        offerId: 'offer2',
        contentType: 'text/plain',
        byteSize: 12,
        sha256: 'hash2',
        expiresInMs: 10000,
        localDeviceId: 'deviceA',
        contentBase64: 'SGVsbG8gV29ybGQ=',
      );

      expect(offer2.offerSequence, 2);
    });

    test('processIncomingOffer accepts new valid offer', () {
      final offer = ClipboardOffer(
        offerId: 'offer1',
        contentType: 'text/plain',
        byteSize: 10,
        sha256: 'hash',
        expiresInMs: 10000,
        sourceDeviceId: 'peerA',
        requiredCapability: 'clipboard.offer_fetch',
        offerSequence: 1,
      );

      final accepted = engine.processIncomingOffer(offer);
      expect(accepted, isTrue);
      expect(engine.getAllOffers().length, 1);
      expect(engine.getOffer('offer1'), offer);
    });

    test('processIncomingOffer rejects replay or out-of-order sequence', () {
      final offer1 = ClipboardOffer(
        offerId: 'offer1',
        contentType: 'text/plain',
        byteSize: 10,
        sha256: 'hash',
        expiresInMs: 10000,
        sourceDeviceId: 'peerA',
        requiredCapability: 'clipboard.offer_fetch',
        offerSequence: 5,
      );
      expect(engine.processIncomingOffer(offer1), isTrue);

      final offer2Replay = ClipboardOffer(
        offerId: 'offer2',
        contentType: 'text/plain',
        byteSize: 10,
        sha256: 'hash',
        expiresInMs: 10000,
        sourceDeviceId: 'peerA',
        requiredCapability: 'clipboard.offer_fetch',
        offerSequence: 5,
      );
      expect(engine.processIncomingOffer(offer2Replay), isFalse, reason: 'Sequence same as high-water mark should be rejected');

      final offer3OutOfOrder = ClipboardOffer(
        offerId: 'offer3',
        contentType: 'text/plain',
        byteSize: 10,
        sha256: 'hash',
        expiresInMs: 10000,
        sourceDeviceId: 'peerA',
        requiredCapability: 'clipboard.offer_fetch',
        offerSequence: 4,
      );
      expect(engine.processIncomingOffer(offer3OutOfOrder), isFalse, reason: 'Sequence lower than high-water mark should be rejected');
      
      expect(engine.getAllOffers().length, 1);
    });

    test('offer expires after expiresInMs', () async {
      final expiredCompleter = expectAsync1((String id) {
        expect(id, 'offer1');
      });
      engine.onOfferExpired.listen(expiredCompleter);

      engine.createLocalOffer(
        offerId: 'offer1',
        contentType: 'text/plain',
        byteSize: 10,
        sha256: 'hash',
        expiresInMs: 50, // Short expiry for test
        localDeviceId: 'deviceA',
        contentBase64: 'dGVzdA==',
      );

      expect(engine.getAllOffers().length, 1);
      
      await Future.delayed(Duration(milliseconds: 100));

      expect(engine.getAllOffers().length, 0);
    });

    test('getIncomingOffers excludes local offers', () {
      engine.createLocalOffer(
        offerId: 'local-offer',
        contentType: 'text/plain',
        byteSize: 4,
        sha256: 'hash',
        expiresInMs: 10000,
        localDeviceId: 'deviceA',
        contentBase64: 'dGVzdA==',
      );

      final remoteOffer = ClipboardOffer(
        offerId: 'remote-offer',
        contentType: 'text/plain',
        byteSize: 4,
        sha256: 'hash',
        expiresInMs: 10000,
        sourceDeviceId: 'peerA',
        requiredCapability: 'clipboard.offer_fetch',
        offerSequence: 1,
      );
      expect(engine.processIncomingOffer(remoteOffer), isTrue);

      final incoming = engine.getIncomingOffers();
      expect(incoming.map((offer) => offer.offerId), ['remote-offer']);
      expect(engine.isLocalOffer('local-offer'), isTrue);
      expect(engine.isLocalOffer('remote-offer'), isFalse);
    });
  });
}
