import 'dart:convert';

import 'package:app_flutter/src/ipc/in_process_daemon_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDaemon implements InProcessDaemon {
  _FakeDaemon(this.onIpcEvent);

  final void Function(Map<String, dynamic>) onIpcEvent;
  bool started = false;
  bool stopped = false;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<Map<String, dynamic>> handleJsonRpcRequest(
    Map<String, dynamic> request,
  ) async {
    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onTrustChanged',
      'params': {
        'deviceId': 'rift-peer',
        'previousState': 'discovered',
        'newState': 'trusted',
      },
    });
    return {
      'method': request['method'],
      'deviceId': 'rift-ios',
    };
  }
}

void main() {
  test('forwards daemon notifications and request responses', () async {
    late _FakeDaemon daemon;
    final transport = InProcessDaemonTransport(
      storagePathProvider: () async => '/tmp/rift-test',
      daemonFactory: (storagePath, onIpcEvent) {
        expect(storagePath, '/tmp/rift-test');
        daemon = _FakeDaemon(onIpcEvent);
        return daemon;
      },
    );

    final channel = await transport.connect();
    final messages = <Map<String, dynamic>>[];
    final subscription = channel.stream.listen((message) {
      messages.add(Map<String, dynamic>.from(jsonDecode(message) as Map));
    });

    channel.sink.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'rift.getDeviceInfo',
      'params': <String, dynamic>{},
    }));

    await pumpEventQueue();

    expect(daemon.started, isTrue);
    expect(messages, hasLength(2));
    expect(messages.first['method'], 'rift.onTrustChanged');
    expect(messages.last['result'], {
      'method': 'rift.getDeviceInfo',
      'deviceId': 'rift-ios',
    });

    await subscription.cancel();
    await transport.disconnect();
    expect(daemon.stopped, isTrue);
  });
}
