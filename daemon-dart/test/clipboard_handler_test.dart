import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/clipboard/clipboard_engine.dart';
import 'package:daemon_dart/src/clipboard/clipboard_handler.dart';
import 'package:daemon_dart/src/clipboard/clipboard_models.dart';

// Fake SessionManager for testing
class FakeSessionManager implements SessionManager {
  final StreamController<ProtocolMessage> _onMessageController = StreamController<ProtocolMessage>.broadcast();
  
  @override
  Stream<ProtocolMessage> get onMessage => _onMessageController.stream;

  final List<Map<String, dynamic>> sentMessages = [];

  @override
  void requireCapability(String peerDeviceId, String capabilityName) {
    // allow all in fake
  }

  @override
  Future<void> sendMessage(String peerDeviceId, Map<String, dynamic> payload) async {
    sentMessages.add(payload);
  }

  void injectMessage(ProtocolMessage msg) {
    _onMessageController.add(msg);
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ClipboardProtocolHandler', () {
    late ClipboardEngine engine;
    late FakeSessionManager sessionManager;
    late ClipboardProtocolHandler handler;

    setUp(() {
      engine = ClipboardEngine();
      sessionManager = FakeSessionManager();
      handler = ClipboardProtocolHandler(sessionManager, engine, (offerId) async {
         if (offerId == 'valid-offer') {
           return base64.encode(utf8.encode('Hello World'));
         }
         return null;
      }, 'localDevId');
    });

    tearDown(() {
      handler.dispose();
      engine.dispose();
    });

    test('Incoming offer is processed and engine is updated', () async {
      final msg = ProtocolMessage('peerA', null, {
        'type': 'clipboard.offer',
        'payload': {
          'offerId': 'offer1',
          'contentType': 'text/plain',
          'byteSize': 10,
          'sha256': 'hash',
          'expiresInMs': 10000,
          'sourceDeviceId': 'peerA',
          'requiredCapability': 'clipboard.offer_fetch',
          'offerSequence': 1,
        }
      });
      sessionManager.injectMessage(msg);
      
      // wait a tick
      await Future.delayed(Duration(milliseconds: 50));
      
      expect(engine.getOffer('offer1'), isNotNull);
    });

    test('Incoming offer with wrong sourceDeviceId is rejected', () async {
      final msg = ProtocolMessage('peerA', null, {
        'type': 'clipboard.offer',
        'payload': {
          'offerId': 'offer2',
          'contentType': 'text/plain',
          'byteSize': 10,
          'sha256': 'hash',
          'expiresInMs': 10000,
          'sourceDeviceId': 'peerB', // mismatch
          'requiredCapability': 'clipboard.offer_fetch',
          'offerSequence': 1,
        }
      });
      sessionManager.injectMessage(msg);
      
      await Future.delayed(Duration(milliseconds: 50));
      
      expect(engine.getOffer('offer2'), isNull);
    });

    test('FetchRequest for local offer sends correct fetchResponse', () async {
      final content = 'Hello World';
      final bytes = utf8.encode(content);
      final hash = sha256.convert(bytes).toString();

      engine.createLocalOffer(
        offerId: 'valid-offer',
        contentType: 'text/plain',
        byteSize: bytes.length,
        sha256: hash,
        expiresInMs: 10000,
        localDeviceId: 'localDevId',
        contentBase64: base64.encode(bytes),
      );

      final msg = ProtocolMessage('peerA', null, {
        'type': 'clipboard.fetchRequest',
        'payload': {
          'offerId': 'valid-offer',
          'requestingDeviceId': 'peerA',
        }
      });
      sessionManager.injectMessage(msg);

      await Future.delayed(Duration(milliseconds: 50));

      expect(sessionManager.sentMessages.length, 1);
      final sent = sessionManager.sentMessages[0];
      expect(sent['type'], 'clipboard.fetchResponse');
      expect(sent['payload']['sha256'], hash);
      expect(sent['payload']['contentBase64'], base64.encode(bytes));
    });

    test('Incoming fetchResponse with valid hash emits event', () async {
      final content = 'Remote Data';
      final bytes = utf8.encode(content);
      final hash = sha256.convert(bytes).toString();

      ClipboardFetchResponse? receivedResponse;
      handler.onFetchResponse.listen((r) => receivedResponse = r);

      final msg = ProtocolMessage('peerA', null, {
        'type': 'clipboard.fetchResponse',
        'payload': {
          'offerId': 'offerA',
          'contentBase64': base64.encode(bytes),
          'byteSize': bytes.length,
          'sha256': hash,
        }
      });
      sessionManager.injectMessage(msg);

      await Future.delayed(Duration(milliseconds: 50));

      expect(receivedResponse, isNotNull);
      expect(receivedResponse!.sha256, hash);
    });

    test('Incoming fetchResponse with invalid hash is dropped', () async {
      final content = 'Remote Data';
      final bytes = utf8.encode(content);

      ClipboardFetchResponse? receivedResponse;
      handler.onFetchResponse.listen((r) => receivedResponse = r);

      final msg = ProtocolMessage('peerA', null, {
        'type': 'clipboard.fetchResponse',
        'payload': {
          'offerId': 'offerA',
          'contentBase64': base64.encode(bytes),
          'byteSize': bytes.length,
          'sha256': 'wrong-hash',
        }
      });
      sessionManager.injectMessage(msg);

      await Future.delayed(Duration(milliseconds: 50));

      expect(receivedResponse, isNull);
    });
    test('Incoming offer with byteSize > 32MiB is dropped', () async {
      final msg = ProtocolMessage('peerA', null, {
        'type': 'clipboard.offer',
        'payload': {
          'offerId': 'large-offer',
          'contentType': 'text/plain',
          'byteSize': 33 * 1024 * 1024, // 33 MiB
          'sha256': 'hash',
          'expiresInMs': 10000,
          'sourceDeviceId': 'peerA',
          'requiredCapability': 'clipboard.offer_fetch',
          'offerSequence': 2,
        }
      });
      sessionManager.injectMessage(msg);
      
      await Future.delayed(Duration(milliseconds: 50));
      
      expect(engine.getOffer('large-offer'), isNull);
    });

    test('Incoming fetchResponse with byteSize > 32MiB is dropped', () async {
      ClipboardFetchResponse? receivedResponse;
      handler.onFetchResponse.listen((r) => receivedResponse = r);

      final msg = ProtocolMessage('peerA', null, {
        'type': 'clipboard.fetchResponse',
        'payload': {
          'offerId': 'large-resp',
          'contentBase64': 'A', // invalid size logically, but the handler only checks `byteSize`
          'byteSize': 33 * 1024 * 1024,
          'sha256': 'hash',
        }
      });
      sessionManager.injectMessage(msg);

      await Future.delayed(Duration(milliseconds: 50));

      expect(receivedResponse, isNull);
    });

    test('FetchRequest for non-local offer returns OfferExpired reject', () async {
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

      final msg = ProtocolMessage('peerB', null, {
        'type': 'clipboard.fetchRequest',
        'payload': {
          'offerId': 'remote-offer',
          'requestingDeviceId': 'peerB',
        }
      });
      sessionManager.injectMessage(msg);

      await Future.delayed(Duration(milliseconds: 50));

      expect(sessionManager.sentMessages.length, 1);
      final sent = sessionManager.sentMessages[0];
      expect(sent['type'], 'clipboard.fetchReject');
      expect(sent['payload']['failureReason'], 'OfferExpired');
    });
  });
}
