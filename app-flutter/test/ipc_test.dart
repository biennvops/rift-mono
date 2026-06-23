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
  String listTrustedPeersJson =
      '{"Peers":[{"DeviceId":"rift-peer","TrustState":"pairingpending","Presence":"offline","Capabilities":[]}]}';
  Map<String, dynamic> startPairingResult = {
    'Fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    'PeerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    'ExpiresInMs': 120000,
  };

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

  @override
  Future<StreamChannel<String>> connect() async {
    connectionAttempts++;
    if (shouldFailConnect) {
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
            'TrustedDeviceId': (decoded['params'] as Map<String, dynamic>)['deviceId'],
            'PersistedAt': '2026-06-24T02:00:00Z',
          });
          break;
        case 'rift.rejectPairing':
          _sendResult(id, {'Rejected': true});
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
            'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
            'implementationId': 'riftd-cs/0.1.0',
            'protocolVersion': '0.1-draft',
            'capabilities': [
              {'name': 'clipboard.offer_fetch', 'version': 1}
            ]
          }));
    });

    test('should canonicalize C# trust state enum values to IPC format', () async {
      await client.connect();

      final result = await client.listTrustedPeers();
      expect(
        result,
        equals({
          'peers': [
            {
              'deviceId': 'rift-peer',
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
        
        async.elapse(const Duration(seconds: 1)); // First backoff is 1s (1 << 0)
        async.flushMicrotasks();
        
        // It should have attempted exactly 1 more time
        expect(transport.connectionAttempts, equals(attemptsAfterFirstReconnect + 1));
        
        // Manually disconnect to avoid tearDown hanging outside fakeAsync
        client.disconnect();
        async.flushMicrotasks();
      });
    });

    test('should deliver incoming pairing request notification with canonicalized fields', () async {
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

    test('Linux to Android style flow: approve sends correct IPC request and receives completion events',
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

    test('Android to Linux style flow: startPairing returns fingerprints and daemon can close pending flow',
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
