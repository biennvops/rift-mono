import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:app_flutter/src/ipc/ipc_transport.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';

class MockTransport implements IpcTransport {
  StreamController<String>? _daemonToApp;
  StreamController<String>? _appToDaemon;

  bool isConnected = false;
  int connectionAttempts = 0;
  bool shouldFailConnect = false;

  void triggerDisconnect() {
    _daemonToApp?.close();
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

    // Simulate daemon responding to ping
    _appToDaemon!.stream.listen((req) {
      if (req.contains('"method":"rift.getDeviceInfo"')) {
        // Extract ID to form proper JSON-RPC response
        final match = RegExp(r'"id":(\d+)').firstMatch(req);
        final id = match?.group(1) ?? '1';
        final mockJson =
            '{"deviceId":"rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq","fingerprint":"CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ","implementationId":"riftd-cs/0.1.0","protocolVersion":"0.1-draft","capabilities":[{"name":"clipboard.offer_fetch","version":1}]}';
        _daemonToApp?.add('{"jsonrpc":"2.0","result":$mockJson,"id":$id}');
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
  });
}
