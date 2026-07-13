import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:app_flutter/src/ipc/ipc_transport.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';

class MockTransport implements IpcTransport {
  StreamController<String>? _daemonToApp;
  StreamController<String>? _appToDaemon;
  final List<Map<String, dynamic>> requests = [];

  bool isConnected = false;
  int connectionAttempts = 0;
  bool shouldFailConnect = false;
  int failConnectAttempts = 0;
  String listTrustedPeersJson =
      '{"Peers":[{"DeviceId":"rift-peer","Platform":"windows","TrustState":"pairingpending","Presence":"offline","Capabilities":[]}]}';
  Map<String, dynamic> startPairingResult = {
    'Fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    'PeerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    'ExpiresInMs': 120000,
  };
  Map<String, dynamic> notifyClipboardChangeResult = {
    'OfferId': 'offer-local',
    'ExpiresInMs': 120000,
    'BroadcastTo': ['rift-peer'],
  };
  Map<String, dynamic> listClipboardOffersResult = {
    'Offers': [
      {
        'OfferId': 'offer-remote',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'text/plain',
        'ByteSize': 5,
        'Sha256': 'abc123',
        'ExpiresAt': '2026-06-30T02:00:00Z',
      }
    ]
  };
  Map<String, dynamic> fetchClipboardContentResult = {
    'OfferId': 'offer-remote',
    'ContentBase64': 'aGVsbG8=',
    'ByteSize': 5,
    'Sha256':
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    'Verified': true,
  };
  Map<String, dynamic> offerFileResult = {
    'TransferId': 'transfer-1',
    'OperationId': 'operation-file-1',
    'TargetDeviceId': 'rift-peer',
    'FileName': 'demo.txt',
    'ByteSize': 12,
    'ChunkSize': 262144,
    'ChunkCount': 1,
  };
  Map<String, dynamic> listIncomingFileOffersResult = {
    'Offers': [
      {
        'TransferId': 'transfer-incoming',
        'SourceDeviceId': 'rift-peer',
        'FileName': 'photo.jpg',
        'MediaType': 'image/jpeg',
        'ByteSize': 1234,
        'Sha256': 'def456',
        'ChunkSize': 262144,
        'ChunkCount': 1,
        'ExpiresAt': '2026-06-30T02:05:00Z',
      }
    ]
  };
  Map<String, dynamic> acceptFileOfferResult = {
    'TransferId': 'transfer-incoming',
    'OperationId': 'operation-file-2',
    'DestinationPath': 'C:/tmp/photo.jpg',
  };
  Map<String, dynamic> rejectFileOfferResult = {
    'TransferId': 'transfer-incoming',
    'Rejected': true,
  };
  Map<String, dynamic> listFileTransfersResult = {
    'Transfers': [
      {
        'TransferId': 'transfer-1',
        'OperationId': 'operation-file-1',
        'Direction': 'incoming',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'BytesTransferred': 12,
        'State': 'Done',
        'DestinationPath': 'C:/tmp/demo.txt',
      }
    ]
  };
  Map<String, dynamic> listOperationsResult = {
    'Operations': [
      {
        'OperationId': 'operation-1',
        'OperationType': 'clipboard.fetch',
        'State': 'Done',
        'SourceDeviceId': 'rift-local',
        'DestinationDeviceId': 'rift-peer',
        'CreatedAt': '2026-06-30T02:00:00Z',
        'UpdatedAt': '2026-06-30T02:00:01Z',
      }
    ],
    'Total': 1,
  };
  Map<String, dynamic> getOperationResult = {
    'OperationId': 'operation-1',
    'OperationType': 'clipboard.fetch',
    'State': 'Done',
    'SourceDeviceId': 'rift-local',
    'DestinationDeviceId': 'rift-peer',
    'CreatedAt': '2026-06-30T02:00:00Z',
    'UpdatedAt': '2026-06-30T02:00:01Z',
    'Transitions': [
      {'From': 'Created', 'To': 'Pending', 'At': '2026-06-30T02:00:00Z'},
      {'From': 'Pending', 'To': 'Dispatched', 'At': '2026-06-30T02:00:00Z'},
      {'From': 'Dispatched', 'To': 'Active', 'At': '2026-06-30T02:00:01Z'},
      {'From': 'Active', 'To': 'Done', 'At': '2026-06-30T02:00:01Z'},
    ],
  };
  Map<String, dynamic>? getOperationError;

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

  void _sendError(dynamic id, Map<String, dynamic> error) {
    _daemonToApp?.add(jsonEncode({
      'jsonrpc': '2.0',
      'error': error,
      'id': id,
    }));
  }

  @override
  Future<StreamChannel<String>> connect() async {
    connectionAttempts++;
    if (shouldFailConnect || failConnectAttempts > 0) {
      if (failConnectAttempts > 0) {
        failConnectAttempts -= 1;
      }
      throw Exception('Mock connection failure');
    }

    isConnected = true;
    _daemonToApp = StreamController<String>();
    _appToDaemon = StreamController<String>();

    // Simulate daemon responding to requests and notifications.
    _appToDaemon!.stream.listen((req) {
      final decoded = jsonDecode(req) as Map<String, dynamic>;
      requests.add(decoded);
      final id = decoded['id'];
      switch (decoded['method']) {
        case 'rift.getDeviceInfo':
          _sendResult(id, {
            'deviceId': 'rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq',
            'platform': 'windows',
            'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
            'implementationId': 'riftd-cs/0.1.0',
            'protocolVersion': '0.1-draft',
            'capabilities': [
              {'name': 'clipboard.offer_fetch', 'version': 1}
            ]
          });
          break;
        case 'rift.listTrustedPeers':
          _sendResult(id, jsonDecode(listTrustedPeersJson));
          break;
        case 'rift.startPairing':
          _sendResult(id, startPairingResult);
          break;
        case 'rift.approvePairing':
          _sendResult(id, {
            'TrustedDeviceId':
                (decoded['params'] as Map<String, dynamic>)['deviceId'],
            'PersistedAt': '2026-06-24T02:00:00Z',
          });
          break;
        case 'rift.rejectPairing':
          _sendResult(id, {'Rejected': true});
          break;
        case 'rift.notifyClipboardChange':
          _sendResult(id, notifyClipboardChangeResult);
          break;
        case 'rift.listClipboardOffers':
          _sendResult(id, listClipboardOffersResult);
          break;
        case 'rift.fetchClipboardContent':
          _sendResult(id, fetchClipboardContentResult);
          break;
        case 'rift.offerFile':
          _sendResult(id, offerFileResult);
          break;
        case 'rift.listIncomingFileOffers':
          _sendResult(id, listIncomingFileOffersResult);
          break;
        case 'rift.acceptFileOffer':
          _sendResult(id, acceptFileOfferResult);
          break;
        case 'rift.rejectFileOffer':
          _sendResult(id, rejectFileOfferResult);
          break;
        case 'rift.listFileTransfers':
          _sendResult(id, listFileTransfersResult);
          break;
        case 'rift.listOperations':
          _sendResult(id, listOperationsResult);
          break;
        case 'rift.getOperation':
          if (getOperationError != null) {
            _sendError(id, getOperationError!);
          } else {
            _sendResult(id, getOperationResult);
          }
          break;
      }
    });

    return StreamChannel<String>(_daemonToApp!.stream, _appToDaemon!.sink);
  }

  @override
  Future<void> disconnect() async {
    isConnected = false;
    _daemonToApp?.close();
    _appToDaemon?.close();
  }
}

void main() {
  group('JsonRpcRiftClient', () {
    late MockTransport transport;
    late JsonRpcRiftClient client;

    setUp(() {
      transport = MockTransport();
      client = JsonRpcRiftClient(transport);
    });

    tearDown(() async {
      await client.disconnect();
    });

    test('should connect via transport', () async {
      await client.connect();
      expect(client.isConnected, isTrue);
      expect(transport.isConnected, isTrue);
    });

    test('should successfully get device info from the daemon', () async {
      await client.connect();
      final result = await client.getDeviceInfo();
      expect(
          result,
          equals({
            'deviceId': 'rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq',
            'platform': 'windows',
            'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
            'implementationId': 'riftd-cs/0.1.0',
            'protocolVersion': '0.1-draft',
            'capabilities': [
              {'name': 'clipboard.offer_fetch', 'version': 1}
            ]
          }));
    });

    test('should canonicalize C# trust state enum values to IPC format',
        () async {
      await client.connect();

      final result = await client.listTrustedPeers();
      expect(
        result,
        equals({
          'peers': [
            {
              'deviceId': 'rift-peer',
              'platform': 'windows',
              'trustState': 'pairing_pending',
              'presence': 'offline',
              'capabilities': <dynamic>[],
            }
          ]
        }),
      );
    });

    test('should format transport and pairing errors for display', () {
      expect(
        JsonRpcRiftClient.formatDisplayError(
          Exception(
            'JSON-RPC error -32000: Failed to establish a secure session with peer',
          ),
        ),
        contains('Could not establish a secure session'),
      );

      expect(
        JsonRpcRiftClient.formatDisplayError(
          StateError('Not connected to daemon'),
        ),
        equals('Daemon not connected.'),
      );

      expect(
        JsonRpcRiftClient.formatDisplayError(
          Exception(
            "JSON-RPC error -32000: Failed to reconnect trusted peer 'rift-nyvhp4uu4axifolkhwvzgoskuytlozui' using discovery endpoints. Peer closed connection before sending session.hello.",
          ),
        ),
        equals(
          'Could not reconnect to this trusted device. Make sure it is online and reachable on the same local network, then try again.',
        ),
      );
    });

    test('should attempt reconnection on unexpected disconnect', () {
      fakeAsync((async) {
        // Connect synchronously within the fake async zone
        client.connect();
        async.flushMicrotasks();

        expect(client.isConnected, isTrue);

        int initialAttempts = transport.connectionAttempts;

        // Trigger disconnect
        transport.triggerDisconnect();
        async.flushMicrotasks(); // Wait for onDone to propagate

        // json_rpc_2 might use futures that we need to yield to.
        // Advance time by 2 seconds to trigger the exponential backoff timer (first wait is 1s)
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        // Should have attempted to reconnect at least once
        expect(transport.connectionAttempts, greaterThan(initialAttempts));

        // Verify reconnect counter reset logic
        // It successfully reconnected, so attempts should be reset to 0.
        // A second disconnect should trigger attempt 1 again (waiting 1 second).
        int attemptsAfterFirstReconnect = transport.connectionAttempts;
        transport.triggerDisconnect();
        async.flushMicrotasks();

        async
            .elapse(const Duration(seconds: 1)); // First backoff is 1s (1 << 0)
        async.flushMicrotasks();

        // It should have attempted exactly 1 more time
        expect(transport.connectionAttempts,
            equals(attemptsAfterFirstReconnect + 1));

        // Manually disconnect to avoid tearDown hanging outside fakeAsync
        client.disconnect();
        async.flushMicrotasks();
      });
    });

    test('should keep retrying reconnect after a failed reconnect attempt', () {
      fakeAsync((async) {
        client.connect();
        async.flushMicrotasks();

        expect(client.isConnected, isTrue);

        transport.failConnectAttempts = 1;
        final initialAttempts = transport.connectionAttempts;

        transport.triggerDisconnect();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(client.isConnected, isFalse);

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(client.isConnected, isTrue);
        expect(transport.connectionAttempts, greaterThan(initialAttempts + 1));

        client.disconnect();
        async.flushMicrotasks();
      });
    });

    test(
        'should deliver incoming pairing request notification with canonicalized fields',
        () async {
      await client.connect();

      final eventFuture = client.onPairingRequest.first;
      transport.emitNotification('rift.onPairingRequest', {
        'DeviceId': 'rift-linux-peer',
        'DisplayName': 'Linux Laptop',
        'Fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'ExpiresInMs': 120000,
      });

      final event = await eventFuture;
      expect(event, {
        'deviceId': 'rift-linux-peer',
        'displayName': 'Linux Laptop',
        'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'expiresInMs': 120000,
      });
    });

    test('should deliver clipboard notifications with canonicalized fields',
        () async {
      await client.connect();

      final offerFuture = client.onClipboardOffer.first;
      final expiredFuture = client.onClipboardExpired.first;

      transport.emitNotification('rift.onClipboardOffer', {
        'OfferId': 'offer-1',
        'SourceDeviceId': 'rift-peer',
        'ContentType': 'text/plain',
        'ByteSize': 5,
        'Sha256': 'abc123',
        'ExpiresInMs': 120000,
      });
      transport.emitNotification('rift.onClipboardExpired', {
        'OfferId': 'offer-1',
      });

      expect(await offerFuture, {
        'offerId': 'offer-1',
        'sourceDeviceId': 'rift-peer',
        'contentType': 'text/plain',
        'byteSize': 5,
        'sha256': 'abc123',
        'expiresInMs': 120000,
      });
      expect(await expiredFuture, {
        'offerId': 'offer-1',
      });
    });

    test('should deliver file transfer notifications with canonicalized fields',
        () async {
      await client.connect();

      final offerFuture = client.onFileOffer.first;
      final progressFuture = client.onFileTransferProgress.first;
      final completedFuture = client.onFileTransferCompleted.first;
      final failedFuture = client.onFileTransferFailed.first;

      transport.emitNotification('rift.onFileOffer', {
        'TransferId': 'transfer-1',
        'SourceDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'Sha256': 'abc123',
        'ChunkSize': 262144,
        'ChunkCount': 1,
        'ExpiresAt': '2026-06-30T02:10:00Z',
      });
      transport.emitNotification('rift.onFileTransferProgress', {
        'TransferId': 'transfer-1',
        'OperationId': 'operation-file-1',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'MediaType': 'text/plain',
        'ByteSize': 12,
        'BytesTransferred': 6,
        'State': 'Active',
      });
      transport.emitNotification('rift.onFileTransferCompleted', {
        'TransferId': 'transfer-1',
        'OperationId': 'operation-file-1',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'demo.txt',
        'ByteSize': 12,
        'DestinationPath': 'C:/tmp/demo.txt',
      });
      transport.emitNotification('rift.onFileTransferFailed', {
        'TransferId': 'transfer-2',
        'OperationId': 'operation-file-2',
        'PeerDeviceId': 'rift-peer',
        'FileName': 'bad.bin',
        'ByteSize': 8,
        'FailureReason': 'ConnectionLost',
      });

      expect(await offerFuture, {
        'transferId': 'transfer-1',
        'sourceDeviceId': 'rift-peer',
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
        'byteSize': 12,
        'sha256': 'abc123',
        'chunkSize': 262144,
        'chunkCount': 1,
        'expiresAt': '2026-06-30T02:10:00Z',
      });
      expect(await progressFuture, {
        'transferId': 'transfer-1',
        'operationId': 'operation-file-1',
        'peerDeviceId': 'rift-peer',
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
        'byteSize': 12,
        'bytesTransferred': 6,
        'state': 'Active',
      });
      expect(await completedFuture, {
        'transferId': 'transfer-1',
        'operationId': 'operation-file-1',
        'peerDeviceId': 'rift-peer',
        'fileName': 'demo.txt',
        'byteSize': 12,
        'destinationPath': 'C:/tmp/demo.txt',
      });
      expect(await failedFuture, {
        'transferId': 'transfer-2',
        'operationId': 'operation-file-2',
        'peerDeviceId': 'rift-peer',
        'fileName': 'bad.bin',
        'byteSize': 8,
        'failureReason': 'ConnectionLost',
      });
    });

    test('should expose clipboard RPC wrappers', () async {
      await client.connect();

      final notifyResult = await client.notifyClipboardChange(
        contentType: 'text/plain',
        byteSize: 5,
        sha256:
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        contentBase64: 'aGVsbG8=',
      );
      final offersResult = await client.listClipboardOffers();
      final fetchResult = await client.fetchClipboardContent('offer-remote');

      expect(notifyResult, {
        'offerId': 'offer-local',
        'expiresInMs': 120000,
        'broadcastTo': ['rift-peer'],
      });
      expect(offersResult, {
        'offers': [
          {
            'offerId': 'offer-remote',
            'sourceDeviceId': 'rift-peer',
            'contentType': 'text/plain',
            'byteSize': 5,
            'sha256': 'abc123',
            'expiresAt': '2026-06-30T02:00:00Z',
          }
        ]
      });
      expect(fetchResult, {
        'offerId': 'offer-remote',
        'contentBase64': 'aGVsbG8=',
        'byteSize': 5,
        'sha256':
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'verified': true,
      });

      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.notifyClipboardChange')
            .single['params'],
        {
          'contentType': 'text/plain',
          'byteSize': 5,
          'sha256':
              '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
          'contentBase64': 'aGVsbG8=',
        },
      );
      expect(
        transport.requests
            .where(
                (request) => request['method'] == 'rift.fetchClipboardContent')
            .single['params'],
        {'offerId': 'offer-remote'},
      );
    });

    test('should expose file transfer RPC wrappers', () async {
      await client.connect();

      final offerResult = await client.offerFile(
        targetDeviceId: 'rift-peer',
        localPath: 'C:/tmp/demo.txt',
        fileName: 'demo.txt',
        mediaType: 'text/plain',
      );
      final incomingOffers = await client.listIncomingFileOffers();
      final acceptResult = await client.acceptFileOffer(
        transferId: 'transfer-incoming',
        destinationPath: 'C:/tmp/photo.jpg',
      );
      final rejectResult = await client.rejectFileOffer(
        transferId: 'transfer-incoming',
        failureReason: 'PolicyDenied',
        message: 'User declined',
      );
      final transfers = await client.listFileTransfers();

      expect(offerResult['transferId'], 'transfer-1');
      expect(incomingOffers['offers'], hasLength(1));
      expect(acceptResult['destinationPath'], 'C:/tmp/photo.jpg');
      expect(rejectResult['rejected'], isTrue);
      expect(transfers['transfers'], hasLength(1));
    });

    test('should expose operation RPC wrappers', () async {
      await client.connect();

      final listed = await client.listOperations();
      final detailed = await client.getOperation('operation-1');

      expect(listed, {
        'operations': [
          {
            'operationId': 'operation-1',
            'operationType': 'clipboard.fetch',
            'state': 'Done',
            'sourceDeviceId': 'rift-local',
            'destinationDeviceId': 'rift-peer',
            'createdAt': '2026-06-30T02:00:00Z',
            'updatedAt': '2026-06-30T02:00:01Z',
          }
        ],
        'total': 1,
      });
      expect(detailed['operationId'], 'operation-1');
      expect((detailed['transitions'] as List).length, 4);
      expect(
        transport.requests
            .where((request) => request['method'] == 'rift.getOperation')
            .single['params'],
        {'operationId': 'operation-1'},
      );
    });

    test('should surface getOperation not found JSON-RPC errors', () async {
      transport.getOperationError = {
        'code': -32009,
        'message': 'Operation not found',
      };
      await client.connect();

      await expectLater(
        client.getOperation('missing-operation'),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('JSON-RPC error -32009') &&
                error.toString().contains('Operation not found'),
          ),
        ),
      );
    });

    test('should preserve spec casing for operation transition notifications',
        () async {
      await client.connect();

      final transitionFuture = client.onOperationTransition.first;
      transport.emitNotification('rift.onOperationTransition', {
        'OperationId': 'operation-1',
        'OperationType': 'clipboard.fetch',
        'PreviousState': 'Pending',
        'NextState': 'Done',
      });

      final transition = await transitionFuture;
      expect(transition, {
        'operationId': 'operation-1',
        'operationType': 'clipboard.fetch',
        'previousState': 'Pending',
        'nextState': 'Done',
      });
    });

    test('should preserve failureReason on operation transition notifications',
        () async {
      await client.connect();

      final transitionFuture = client.onOperationTransition.first;
      transport.emitNotification('rift.onOperationTransition', {
        'OperationId': 'operation-2',
        'OperationType': 'clipboard.fetch',
        'PreviousState': 'Active',
        'NextState': 'Failed',
        'FailureReason': 'PeerUnreachable',
      });

      final transition = await transitionFuture;
      expect(transition, {
        'operationId': 'operation-2',
        'operationType': 'clipboard.fetch',
        'previousState': 'Active',
        'nextState': 'Failed',
        'failureReason': 'PeerUnreachable',
      });
    });

    test(
        'Linux to Android style flow: approve sends correct IPC request and receives completion events',
        () async {
      await client.connect();

      final requestFuture = client.onPairingRequest.first;
      transport.emitNotification('rift.onPairingRequest', {
        'DeviceId': 'rift-android-peer',
        'DisplayName': 'Android Phone',
        'Fingerprint': 'PEER-1111-2222-3333-4444-5555-6666-7777-8888',
        'ExpiresInMs': 120000,
      });
      final requestEvent = await requestFuture;
      expect(requestEvent['deviceId'], 'rift-android-peer');

      await client.approvePairing(
        requestEvent['deviceId'] as String,
        requestEvent['fingerprint'] as String,
      );

      final approveRequest = transport.requests.last;
      expect(approveRequest['method'], 'rift.approvePairing');
      expect(approveRequest['params'], {
        'deviceId': 'rift-android-peer',
        'fingerprint': 'PEER-1111-2222-3333-4444-5555-6666-7777-8888',
      });

      final trustChangedFuture = client.onTrustChanged.first;
      final pairingCompleteFuture = client.onPairingComplete.first;
      transport.emitNotification('rift.onTrustChanged', {
        'DeviceId': 'rift-android-peer',
        'PreviousState': 'pairingPending',
        'NewState': 'trusted',
        'Reason': 'pairing.completed',
      });
      transport.emitNotification('rift.onPairingComplete', {
        'DeviceId': 'rift-android-peer',
        'Fingerprint': 'PEER-1111-2222-3333-4444-5555-6666-7777-8888',
        'PersistedAt': '2026-06-24T02:01:00Z',
      });

      final trustChanged = await trustChangedFuture;
      final pairingComplete = await pairingCompleteFuture;
      expect(trustChanged['newState'], 'trusted');
      expect(trustChanged['previousState'], 'pairing_pending');
      expect(pairingComplete['deviceId'], 'rift-android-peer');
      expect(pairingComplete['fingerprint'],
          'PEER-1111-2222-3333-4444-5555-6666-7777-8888');
    });

    test(
        'Android to Linux style flow: startPairing returns fingerprints and daemon can close pending flow',
        () async {
      await client.connect();

      final startResult =
          await client.startPairing('rift-linux-peer') as Map<String, dynamic>;
      expect(startResult, {
        'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'peerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'expiresInMs': 120000,
      });

      final startRequest = transport.requests.last;
      expect(startRequest['method'], 'rift.startPairing');
      expect(startRequest['params'], {'deviceId': 'rift-linux-peer'});

      final trustChangedFuture = client.onTrustChanged.first;
      transport.emitNotification('rift.onTrustChanged', {
        'DeviceId': 'rift-linux-peer',
        'PreviousState': 'pairingPending',
        'NewState': 'discovered',
        'Reason': 'pairing.closed',
      });

      final trustChanged = await trustChangedFuture;
      expect(trustChanged['deviceId'], 'rift-linux-peer');
      expect(trustChanged['previousState'], 'pairing_pending');
      expect(trustChanged['newState'], 'discovered');
      expect(trustChanged['reason'], 'pairing.closed');
    });
  });
}
