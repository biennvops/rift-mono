import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/ipc/android_background_entrypoint.dart';

void main() {
  test('Android background runtime shutdown is idempotent', () async {
    final stopGate = Completer<void>();
    final order = <String>[];
    var stopCalls = 0;
    var remoteMediaDisposeCalls = 0;
    var deviceStatusDisposeCalls = 0;
    var clientDisposeCalls = 0;
    var drainCalls = 0;
    final shutdown = AndroidBackgroundRuntimeShutdown(
      stopEventProducers: () async {
        stopCalls += 1;
        order.add('stop-events');
        await stopGate.future;
      },
      disposeRemoteMedia: () {
        remoteMediaDisposeCalls += 1;
        order.add('remote-media');
      },
      disposeDeviceStatusPublisher: () {
        deviceStatusDisposeCalls += 1;
        order.add('device-status');
      },
      disposeClient: () {
        clientDisposeCalls += 1;
        order.add('client');
      },
      drainOwnedWork: () {
        drainCalls += 1;
        order.add('drain');
      },
    );

    final first = shutdown.shutdown();
    final second = shutdown.shutdown();
    expect(shutdown.isShuttingDown, isTrue);
    expect(stopCalls, 1);
    expect(remoteMediaDisposeCalls, 0);

    stopGate.complete();
    await Future.wait([first, second]);
    await shutdown.shutdown();

    expect(stopCalls, 1);
    expect(remoteMediaDisposeCalls, 1);
    expect(deviceStatusDisposeCalls, 1);
    expect(clientDisposeCalls, 1);
    expect(drainCalls, 1);
    expect(
      order,
      <String>[
        'stop-events',
        'remote-media',
        'device-status',
        'client',
        'drain',
      ],
    );
  });

  test('client disposal precedes draining residual owned work', () async {
    final drainStarted = Completer<void>();
    final drainGate = Completer<void>();
    var clientDisposeCalls = 0;
    final shutdown = AndroidBackgroundRuntimeShutdown(
      stopEventProducers: () {},
      disposeRemoteMedia: () {},
      disposeDeviceStatusPublisher: () {},
      disposeClient: () {
        clientDisposeCalls += 1;
      },
      drainOwnedWork: () async {
        drainStarted.complete();
        await drainGate.future;
      },
    );

    final pending = shutdown.shutdown();
    await drainStarted.future;

    expect(clientDisposeCalls, 1);
    drainGate.complete();
    await pending;
  });

  test('a failed ancillary disposer does not skip client disposal', () async {
    var clientDisposeCalls = 0;
    final logs = <String>[];
    final shutdown = AndroidBackgroundRuntimeShutdown(
      stopEventProducers: () {},
      disposeRemoteMedia: () => throw StateError('media dispose failed'),
      disposeDeviceStatusPublisher: () {},
      disposeClient: () {
        clientDisposeCalls += 1;
      },
      drainOwnedWork: () {},
      logger: logs.add,
    );

    await shutdown.shutdown();

    expect(clientDisposeCalls, 1);
    expect(logs.join('\n'), contains('Failed to dispose remote media'));
    expect(logs.last, 'Dart runtime shutdown complete');
  });
}
