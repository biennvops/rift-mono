import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:app_flutter/src/ipc/ipc_transport.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';

class MockTransport implements IpcTransport {
  final StreamController<String> _daemonToApp = StreamController<String>();
  final StreamController<String> _appToDaemon = StreamController<String>();

  bool isConnected = false;

  @override
  Future<StreamChannel<String>> connect() async {
    isConnected = true;

    // Simulate daemon responding to ping
    _appToDaemon.stream.listen((req) {
      if (req.contains('"method":"rift.getDeviceInfo"')) {
        // Extract ID to form proper JSON-RPC response
        final match = RegExp(r'"id":(\d+)').firstMatch(req);
        final id = match?.group(1) ?? '1';
        final mockJson =
            '{"deviceId":"rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq","fingerprint":"CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ","implementationId":"riftd-cs/0.1.0","protocolVersion":"0.1-draft","capabilities":[{"name":"clipboard.offer_fetch","version":1}]}';
        _daemonToApp.add('{"jsonrpc":"2.0","result":$mockJson,"id":$id}');
      }
    });

    return StreamChannel<String>(_daemonToApp.stream, _appToDaemon.sink);
  }

  @override
  Future<void> disconnect() async {
    isConnected = false;
    await _daemonToApp.close();
    await _appToDaemon.close();
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
  });
}
