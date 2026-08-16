import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/device_status/device_status_publisher.dart';
import 'package:rift/src/ipc/android_background_entrypoint.dart';
import 'package:rift/src/ipc/ipc_transport.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/media_playback/android_remote_media_playback_coordinator.dart';
import 'package:rift/src/platform/android_shell.dart';
import 'package:stream_channel/stream_channel.dart';

class _NoopTransport implements IpcTransport {
  @override
  Future<StreamChannel<String>> connect() => throw UnimplementedError();

  @override
  Future<void> disconnect() async {}
}

class _BlockingOwnerClient extends JsonRpcRiftClient {
  _BlockingOwnerClient() : super(_NoopTransport());

  final _connectionChanges = StreamController<bool>.broadcast();
  Completer<void>? mediaRefreshStarted;
  Completer<void>? mediaRefreshGate;
  int statusPublications = 0;
  int disposeCalls = 0;

  @override
  bool get isConnected => true;

  @override
  Stream<bool> get onConnectionChanged => _connectionChanges.stream;

  @override
  Future<dynamic> getDeviceInfo() async => {'deviceId': 'local-device'};

  @override
  Future<dynamic> listMediaPlayback() async {
    final started = mediaRefreshStarted;
    final gate = mediaRefreshGate;
    if (started != null && gate != null) {
      mediaRefreshStarted = null;
      mediaRefreshGate = null;
      started.complete();
      await gate.future;
    }
    return {'playbacks': <Map<String, dynamic>>[]};
  }

  @override
  Future<dynamic> notifyLocalDeviceStatus({
    bool? batteryPresent,
    int? batteryPercent,
    String? chargingState,
    String? powerSource,
    bool? lowPowerMode,
    String? observedAt,
    String? sourcePlatform,
  }) async {
    statusPublications += 1;
    return null;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    await _connectionChanges.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('shutdown waits for post-start media and status work', () async {
    const shellChannel = MethodChannel('rift/android/shell');
    final mediaRefreshStarted = Completer<void>();
    final mediaRefreshGate = Completer<void>();
    final statusPublicationStarted = Completer<void>();
    final statusPublicationGate = Completer<void>();
    final deviceStatusDisposeStarted = Completer<void>();
    final client = _BlockingOwnerClient();
    final remoteMedia = AndroidRemoteMediaPlaybackCoordinator(client);
    var blockStatusRead = false;
    final deviceStatus = DeviceStatusPublisher(
      client,
      readCurrentStatus: () async {
        if (blockStatusRead) {
          blockStatusRead = false;
          statusPublicationStarted.complete();
          await statusPublicationGate.future;
        }
        return <String, Object?>{
          'batteryPresent': true,
          'batteryPercent': 80,
          'chargingState': 'discharging',
          'powerSource': 'battery',
          'sourcePlatform': 'android',
        };
      },
    );
    Future<void>? refresh;
    Future<void>? publication;
    Future<void>? shutdownFuture;
    var nativeCalls = 0;
    var shutdownComplete = false;

    AndroidShell.debugIsAndroidOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shellChannel, (_) async {
      nativeCalls += 1;
      return true;
    });

    try {
      await remoteMedia.start();
      await deviceStatus.start();
      final initialNativeCalls = nativeCalls;
      expect(client.statusPublications, 1);
      client
        ..mediaRefreshStarted = mediaRefreshStarted
        ..mediaRefreshGate = mediaRefreshGate;
      blockStatusRead = true;

      refresh = remoteMedia.refresh();
      publication = deviceStatus.publishCurrentStatus(force: true);
      await Future.wait<void>([
        mediaRefreshStarted.future,
        statusPublicationStarted.future,
      ]);

      final shutdown = AndroidBackgroundRuntimeShutdown(
        stopEventProducers: () {},
        disposeRemoteMedia: remoteMedia.dispose,
        disposeDeviceStatusPublisher: () async {
          deviceStatusDisposeStarted.complete();
          await deviceStatus.dispose();
        },
        disposeClient: client.dispose,
        drainOwnedWork: () {},
      );
      shutdownFuture = shutdown.shutdown().then((_) {
        shutdownComplete = true;
      });

      await Future<void>.delayed(Duration.zero);
      expect(shutdownComplete, isFalse);
      expect(client.disposeCalls, 1);

      mediaRefreshGate.complete();
      await deviceStatusDisposeStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(shutdownComplete, isFalse);
      expect(client.disposeCalls, 1);

      statusPublicationGate.complete();
      await shutdownFuture;
      expect(client.disposeCalls, 1);
      expect(client.statusPublications, 1);
      expect(nativeCalls, initialNativeCalls);
    } finally {
      if (!mediaRefreshGate.isCompleted) mediaRefreshGate.complete();
      if (!statusPublicationGate.isCompleted) statusPublicationGate.complete();
      await refresh;
      await publication;
      await shutdownFuture;
      await remoteMedia.dispose();
      await deviceStatus.dispose();
      if (client.disposeCalls == 0) await client.dispose();
      AndroidShell.debugIsAndroidOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shellChannel, null);
    }
  });
}
