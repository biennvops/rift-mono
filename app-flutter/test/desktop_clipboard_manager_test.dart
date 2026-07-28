import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_flutter/src/clipboard/desktop_clipboard_manager.dart';
import 'package:app_flutter/src/ipc/ipc_transport.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

class ClipboardTransport implements IpcTransport {
  StreamController<String>? _daemonToApp;
  StreamController<String>? _appToDaemon;
  final List<Map<String, dynamic>> requests = [];
  dynamic listClipboardOffersResult = const {'Offers': <dynamic>[]};
  final Map<String, dynamic> fetchResultsByOfferId = <String, dynamic>{};
  int connectionAttempts = 0;

  void triggerDisconnect() {
    _daemonToApp?.close();
  }

  void emitNotification(String method, Map<String, dynamic> params) {
    _daemonToApp?.add(jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    }));
  }

  void _sendResult(dynamic id, dynamic result) {
    _daemonToApp?.add(jsonEncode({
      'jsonrpc': '2.0',
      'result': result,
      'id': id,
    }));
  }

  void _sendError(dynamic id, int code, String message) {
    _daemonToApp?.add(jsonEncode({
      'jsonrpc': '2.0',
      'error': {'code': code, 'message': message},
      'id': id,
    }));
  }

  @override
  Future<StreamChannel<String>> connect() async {
    connectionAttempts++;
    _daemonToApp = StreamController<String>();
    _appToDaemon = StreamController<String>();

    _appToDaemon!.stream.listen((req) async {
      final decoded = jsonDecode(req) as Map<String, dynamic>;
      requests.add(decoded);
      final id = decoded['id'];
      switch (decoded['method']) {
        case 'rift.listClipboardOffers':
          _sendResult(id, listClipboardOffersResult);
          break;
        case 'rift.fetchClipboardContent':
          final offerId =
              (decoded['params'] as Map<String, dynamic>)['offerId'] as String;
          final result = fetchResultsByOfferId[offerId] ?? const {};
          if (result is Exception) {
            _sendError(id, -32009, result.toString());
          } else if (result is Future) {
            _sendResult(id, await result);
          } else {
            _sendResult(id, result);
          }
          break;
        case 'rift.notifyClipboardChange':
          _sendResult(id, const {
            'OfferId': 'local-offer',
            'ExpiresInMs': 120000,
            'BroadcastTo': <String>[],
          });
          break;
      }
    });

    return StreamChannel<String>(_daemonToApp!.stream, _appToDaemon!.sink);
  }

  @override
  Future<void> disconnect() async {
    await _daemonToApp?.close();
    await _appToDaemon?.close();
  }
}

Future<void> waitForCondition(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
  Duration pollInterval = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met before timeout.');
    }
    await Future<void>.delayed(pollInterval);
  }
}

void main() {
  group('DesktopClipboardManager', () {
    late ClipboardTransport transport;
    late JsonRpcRiftClient client;
    late StreamController<Object?> clipboardChanges;
    late List<String> clipboardWrites;
    String? clipboardText;

    setUp(() {
      transport = ClipboardTransport();
      client = JsonRpcRiftClient(transport);
      clipboardChanges = StreamController<Object?>.broadcast();
      clipboardWrites = <String>[];
      clipboardText = null;
    });

    tearDown(() async {
      await clipboardChanges.close();
      await client.dispose();
    });

    test(
        'resyncs clipboard offers on startup and auto-applies text/plain offers',
        () async {
      transport.listClipboardOffersResult = {
        'Offers': [
          {
            'OfferId': 'offer-1',
            'SourceDeviceId': 'rift-peer',
            'ContentType': 'text/plain',
            'ByteSize': 5,
            'Sha256':
                '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
            'ExpiresAt': '2026-06-30T02:00:00Z',
          }
        ]
      };
      transport.fetchResultsByOfferId['offer-1'] = {
        'OfferId': 'offer-1',
        'ContentBase64': 'aGVsbG8=',
        'ByteSize': 5,
        'Sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'Verified': true,
      };
      await client.connect();

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
          clipboardText = text;
        },
      );

      await manager.start();
      await Future<void>.delayed(Duration.zero);

      expect(manager.activeOffers.keys, contains('offer-1'));
      expect(clipboardWrites, ['hello']);
      expect(
        transport.requests
            .where((request) => request['method'] == 'rift.listClipboardOffers')
            .length,
        1,
      );
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.fetchClipboardContent')
            .length,
        1,
      );

      await manager.dispose();
    });

    test('suppresses clipboard echo after applying fetched content', () async {
      transport.fetchResultsByOfferId['offer-echo'] = {
        'OfferId': 'offer-echo',
        'ContentBase64': 'aGVsbG8=',
        'ByteSize': 5,
        'Sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'Verified': true,
      };
      await client.connect();

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
          clipboardText = text;
        },
      );
      await manager.start();

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-echo',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'text/plain',
        'ByteSize': 5,
        'Sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'ExpiresInMs': 120000,
      });
      await Future<void>.delayed(Duration.zero);

      clipboardChanges.add(null);
      await Future<void>.delayed(Duration.zero);
      clipboardChanges.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(clipboardWrites, ['hello']);
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.notifyClipboardChange')
            .isEmpty,
        isTrue,
      );

      await manager.dispose();
    });

    test(
        'suppresses overlapping echoes for sequential fetched clipboard writes',
        () async {
      transport.listClipboardOffersResult = {
        'Offers': [
          {
            'OfferId': 'offer-1',
            'SourceDeviceId': 'rift-peer-a',
            'ContentType': 'text/plain',
            'ByteSize': 5,
            'Sha256':
                '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
            'ExpiresAt': '2026-07-04T02:00:00Z',
          },
          {
            'OfferId': 'offer-2',
            'SourceDeviceId': 'rift-peer-b',
            'ContentType': 'text/plain',
            'ByteSize': 5,
            'Sha256':
                '486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7',
            'ExpiresAt': '2026-07-04T02:01:00Z',
          }
        ]
      };
      transport.fetchResultsByOfferId['offer-1'] = {
        'OfferId': 'offer-1',
        'ContentBase64': 'aGVsbG8=',
        'ByteSize': 5,
        'Sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'Verified': true,
      };
      transport.fetchResultsByOfferId['offer-2'] = {
        'OfferId': 'offer-2',
        'ContentBase64': 'd29ybGQ=',
        'ByteSize': 5,
        'Sha256':
            '486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7',
        'Verified': true,
      };
      await client.connect();

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
          clipboardText = text;
        },
      );

      await manager.start();
      await Future<void>.delayed(Duration.zero);

      clipboardText = 'hello';
      clipboardChanges.add(null);
      await Future<void>.delayed(Duration.zero);

      clipboardText = 'world';
      clipboardChanges.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(clipboardWrites, ['hello', 'world']);
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.notifyClipboardChange')
            .isEmpty,
        isTrue,
      );

      await manager.dispose();
    });

    test('ignores unsupported content types instead of auto-fetching',
        () async {
      await client.connect();
      final statuses = <String>[];

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
        },
      );
      final statusSub = manager.onStatusUpdate.listen(statuses.add);
      await manager.start();

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-image',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'image/png',
        'ByteSize': 5,
        'Sha256': 'hash-image',
        'ExpiresInMs': 120000,
      });
      await Future<void>.delayed(Duration.zero);

      expect(manager.activeOffers.keys, contains('offer-image'));
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.fetchClipboardContent')
            .isEmpty,
        isTrue,
      );
      expect(clipboardWrites, isEmpty);
      expect(statuses, isEmpty);

      await statusSub.cancel();
      await manager.dispose();
    });

    test('auto-fetches supported image offers when a binary writer is provided',
        () async {
      await client.connect();
      final writtenPayloads = <ClipboardContentPayload>[];
      final statuses = <String>[];
      final pngBytes = Uint8List.fromList(<int>[137, 80, 78, 71, 1, 2, 3, 4]);
      final pngBase64 = base64Encode(pngBytes);

      transport.fetchResultsByOfferId['offer-image'] = {
        'OfferId': 'offer-image',
        'ContentBase64': pngBase64,
        'ByteSize': pngBytes.length,
        'Sha256':
            '0f0516581cb7b841f3d98cbf31cb37b2db5ecff5a1d39d90f307d2f071d8d4f3',
        'Verified': true,
      };

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardContent: (payload) async {
          writtenPayloads.add(payload);
        },
        supportedContentTypes: const <String>{'text/plain', 'image/png'},
      );
      final statusSub = manager.onStatusUpdate.listen(statuses.add);
      await manager.start();

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-image',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'image/png',
        'ByteSize': pngBytes.length,
        'Sha256':
            '0f0516581cb7b841f3d98cbf31cb37b2db5ecff5a1d39d90f307d2f071d8d4f3',
        'ExpiresInMs': 120000,
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.fetchClipboardContent')
            .length,
        1,
      );
      expect(writtenPayloads, hasLength(1));
      expect(writtenPayloads.single.contentType, 'image/png');
      expect(writtenPayloads.single.bytes, orderedEquals(pngBytes));
      expect(statuses, contains('Clipboard content received from peer'));

      await statusSub.cancel();
      await manager.dispose();
    });

    test('sends binary clipboard payloads when a content reader is provided',
        () async {
      await client.connect();
      final imagePayload = ClipboardContentPayload(
        contentType: 'image/png',
        bytes: Uint8List.fromList(<int>[137, 80, 78, 71, 9, 8, 7, 6]),
      );

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardContent: () async => imagePayload,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
        },
        supportedContentTypes: const <String>{'text/plain', 'image/png'},
      );
      await manager.start();

      clipboardChanges.add(null);
      await Future<void>.delayed(Duration.zero);

      final request = transport.requests.singleWhere(
        (candidate) => candidate['method'] == 'rift.notifyClipboardChange',
      );
      expect(
        request['params'],
        containsPair('contentType', 'image/png'),
      );
      expect(
        request['params'],
        containsPair('byteSize', imagePayload.byteSize),
      );
      expect(
        request['params'],
        containsPair('contentBase64', imagePayload.contentBase64),
      );
      expect(
        request['params'],
        containsPair('sha256', imagePayload.sha256Hex),
      );

      await manager.dispose();
    });

    test('does not emit status after dispose while fetch is still in flight',
        () async {
      await client.connect();
      final fetchGate = Completer<void>();
      final statuses = <String>[];

      transport.fetchResultsByOfferId['offer-slow'] = Future<dynamic>(() async {
        await fetchGate.future;
        return {
          'OfferId': 'offer-slow',
          'ContentBase64': 'aGVsbG8=',
          'ByteSize': 5,
          'Sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'Verified': true,
        };
      });

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
          clipboardText = text;
        },
      );
      final statusSub = manager.onStatusUpdate.listen(statuses.add);
      await manager.start();

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-slow',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'text/plain',
        'ByteSize': 5,
        'Sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'ExpiresInMs': 120000,
      });
      await Future<void>.delayed(Duration.zero);
      expect(statuses, contains('Fetching clipboard from peer...'));

      await manager.dispose();
      fetchGate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(clipboardWrites, isEmpty);
      expect(
        statuses.where((status) => status == 'Clipboard received from peer'),
        isEmpty,
      );

      await statusSub.cancel();
    });

    test('keeps clipboard monitoring active while window is hidden', () async {
      await client.connect();

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
          clipboardText = text;
        },
      );
      await manager.start();
      await manager.setWindowVisible(false);

      clipboardText = 'hello';
      clipboardChanges.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.notifyClipboardChange')
            .length,
        1,
      );

      await manager.setWindowVisible(true);
      clipboardText = 'world';
      clipboardChanges.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.notifyClipboardChange')
            .length,
        2,
      );

      await manager.dispose();
    });

    test('removes stale offers when expiry notification arrives', () async {
      await client.connect();

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
        },
      );
      await manager.start();

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-expire',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'image/png',
        'ByteSize': 5,
        'Sha256': 'hash-expire',
        'ExpiresInMs': 120000,
      });
      await Future<void>.delayed(Duration.zero);
      expect(manager.activeOffers.keys, contains('offer-expire'));

      transport.emitNotification('rift.onClipboardExpired', {
        'OfferId': 'offer-expire',
      });
      await Future<void>.delayed(Duration.zero);

      expect(manager.activeOffers.keys, isNot(contains('offer-expire')));

      await manager.dispose();
    });

    test('resync removes handled offers that are no longer active', () async {
      transport.fetchResultsByOfferId['offer-old'] = {
        'OfferId': 'offer-old',
        'ContentBase64': 'aGVsbG8=',
        'ByteSize': 5,
        'Sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'Verified': true,
      };
      transport.fetchResultsByOfferId['offer-new'] = {
        'OfferId': 'offer-new',
        'ContentBase64': 'd29ybGQ=',
        'ByteSize': 5,
        'Sha256':
            '486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7',
        'Verified': true,
      };
      await client.connect();

      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
          clipboardText = text;
        },
      );
      await manager.start();

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-old',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'text/plain',
        'ByteSize': 5,
        'Sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'ExpiresInMs': 120000,
      });
      await Future<void>.delayed(Duration.zero);

      transport.listClipboardOffersResult = {
        'Offers': [
          {
            'OfferId': 'offer-new',
            'SourceDeviceId': 'rift-peer',
            'ContentType': 'text/plain',
            'ByteSize': 5,
            'Sha256':
                '486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7',
            'ExpiresAt': '2026-07-04T02:05:00Z',
          }
        ]
      };
      transport.triggerDisconnect();
      await waitForCondition(() => transport.connectionAttempts >= 2,
          timeout: const Duration(seconds: 3));
      await waitForCondition(
        () => manager.activeOffers.keys.contains('offer-new'),
        timeout: const Duration(seconds: 3),
      );

      expect(manager.activeOffers.keys, isNot(contains('offer-old')));
      expect(manager.activeOffers.keys, contains('offer-new'));
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.fetchClipboardContent')
            .length,
        2,
      );

      await manager.dispose();
    });
    test(
        'polling fallback correctly tracks binary clipboard changes and ignores initial state',
        () async {
      ClipboardContentPayload? mockClipboardState =
          ClipboardContentPayload.text(
        'initial_content',
      );
      Future<ClipboardContentPayload?> mockReader() async => mockClipboardState;

      final pollingStream =
          DesktopClipboardManager.pollClipboardForTesting(mockReader);
      final emittedEvents = <Object?>[];
      final sub = pollingStream.listen(emittedEvents.add);

      // Give it time to do the initial read
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(emittedEvents, isEmpty, reason: 'Should not emit on initial load');

      // First tick with no change
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(emittedEvents, isEmpty,
          reason: 'Should not emit when content is unchanged');

      // Change content
      mockClipboardState = ClipboardContentPayload.text('new_content');
      await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));
      expect(emittedEvents.length, 1,
          reason: 'Should emit once when content changes');

      // Change to null
      mockClipboardState = null;
      await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));
      expect(emittedEvents.length, 1,
          reason: 'Should not emit when content becomes null');

      // Change again
      mockClipboardState = ClipboardContentPayload(
        contentType: 'image/png',
        bytes: Uint8List.fromList(<int>[137, 80, 78, 71, 1, 2, 3]),
      );
      await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));
      expect(emittedEvents.length, 2,
          reason: 'Should emit when content changes again');

      await sub.cancel();
    });

    test(
        'notifies listeners and removes offer when fetch fails with not found error',
        () async {
      final manager = DesktopClipboardManager(
        client,
        clipboardChanges: clipboardChanges.stream,
        readClipboardText: () async => clipboardText,
        writeClipboardText: (text) async {
          clipboardWrites.add(text);
          clipboardText = text;
        },
      );

      var listenerCallCount = 0;
      manager.addListener(() {
        listenerCallCount++;
      });

      unawaited(client.connect());
      await waitForCondition(() => client.isConnected);

      await manager.start();

      transport.emitNotification('rift.onClipboardOffer', {
        'offerId': 'stale-offer-1',
        'sourceDeviceId': 'device-1',
        'contentType': 'text/plain',
        'byteSize': 10,
        'sha256': 'hash1',
      });

      await waitForCondition(
          () => manager.activeOffers.containsKey('stale-offer-1'));
      expect(listenerCallCount, greaterThan(0));

      transport.fetchResultsByOfferId['stale-offer-1'] =
          Exception('-32009 Offer not found');

      final success = await manager.fetchAndApplyOffer('stale-offer-1');
      expect(success, isFalse);
      expect(manager.activeOffers.containsKey('stale-offer-1'), isFalse);

      await manager.dispose();
    });
  });
}
