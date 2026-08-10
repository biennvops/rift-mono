import 'dart:async';
import 'dart:convert';

import 'package:rift/src/ipc/in_process_daemon_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDaemon implements InProcessDaemon {
  _FakeDaemon(
    this.onIpcEvent, {
    this.startError,
    this.startEvent,
    this.startGate,
  });

  final void Function(Map<String, dynamic>) onIpcEvent;
  final Object? startError;
  final Map<String, dynamic>? startEvent;
  final Future<void>? startGate;
  bool started = false;
  bool stopped = false;

  @override
  Future<void> start() async {
    await startGate;
    if (startError != null) {
      throw startError!;
    }
    if (startEvent != null) {
      onIpcEvent(startEvent!);
    }
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
  test('cleans up after startup failure and allows retry', () async {
    var attempts = 0;
    late _FakeDaemon failedDaemon;
    final transport = InProcessDaemonTransport(
      storagePathProvider: () async => '/tmp/rift-test',
      daemonFactory: (storagePath, onIpcEvent) {
        attempts += 1;
        final daemon = _FakeDaemon(
          onIpcEvent,
          startError: attempts == 1 ? StateError('startup failed') : null,
        );
        if (attempts == 1) {
          failedDaemon = daemon;
        }
        return daemon;
      },
    );

    await expectLater(transport.connect(), throwsStateError);
    expect(failedDaemon.stopped, isTrue);

    await transport.connect();
    expect(attempts, 2);
    await transport.disconnect();
  });

  test('shares one daemon startup across concurrent connect calls', () async {
    final startGate = Completer<void>();
    var daemonCount = 0;
    final transport = InProcessDaemonTransport(
      storagePathProvider: () async => '/tmp/rift-test',
      daemonFactory: (storagePath, onIpcEvent) {
        daemonCount += 1;
        return _FakeDaemon(onIpcEvent, startGate: startGate.future);
      },
    );

    final firstConnect = transport.connect();
    final secondConnect = transport.connect();
    await pumpEventQueue();
    expect(daemonCount, 1);

    startGate.complete();
    await Future.wait([firstConnect, secondConnect]);
    expect(daemonCount, 1);
    await transport.disconnect();
  });

  test('stops the daemon when the client closes its channel', () async {
    late _FakeDaemon daemon;
    final transport = InProcessDaemonTransport(
      storagePathProvider: () async => '/tmp/rift-test',
      daemonFactory: (storagePath, onIpcEvent) {
        daemon = _FakeDaemon(onIpcEvent);
        return daemon;
      },
    );

    final channel = await transport.connect();
    await channel.sink.close();
    await pumpEventQueue();

    expect(daemon.stopped, isTrue);
  });

  test('buffers daemon notifications emitted during startup', () async {
    final startupEvent = {
      'jsonrpc': '2.0',
      'method': 'rift.onPairingRequest',
      'params': {
        'deviceId': 'rift-peer',
        'fingerprint': 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
      },
    };
    final transport = InProcessDaemonTransport(
      storagePathProvider: () async => '/tmp/rift-test',
      daemonFactory: (storagePath, onIpcEvent) => _FakeDaemon(
        onIpcEvent,
        startEvent: startupEvent,
      ),
    );

    final channel = await transport.connect();

    expect(
      jsonDecode(await channel.stream.first),
      startupEvent,
    );

    await transport.disconnect();
  });

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
