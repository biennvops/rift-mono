import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/platform/windows_notification_listener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channel = MethodChannelWindowsNotificationListener.methodChannel;
  final calls = <MethodCall>[];

  setUp(() {
    MethodChannelWindowsNotificationListener.debugIsWindowsOverride = true;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getRuntimeStatus':
          return {
            'supported': true,
            'hasPackageIdentity': true,
            'appUserModelId': 'Rift.Desktop!Rift',
            'packageFamilyName': 'Rift.Desktop_dev',
          };
        case 'getAccessStatus':
          return 'allowed';
        case 'requestAccess':
          return 'denied';
        case 'listActive':
          return [
            {
              'eventType': 'posted',
              'userNotificationId': 812,
              'iconBytes': <int>[1, 2, 3],
            },
          ];
        case 'start':
        case 'stop':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    MethodChannelWindowsNotificationListener.debugIsWindowsOverride = null;
    WindowsNotificationListener.platform =
        const MethodChannelWindowsNotificationListener();
  });

  test('parses runtime status and canonical access states', () async {
    const platform = MethodChannelWindowsNotificationListener();

    final runtime = await platform.getRuntimeStatus();
    expect(runtime.supported, isTrue);
    expect(runtime.hasPackageIdentity, isTrue);
    expect(runtime.appUserModelId, 'Rift.Desktop!Rift');

    expect(await platform.getAccessStatus(), 'allowed');
    expect(await platform.requestAccess(), 'denied');
    expect(
      calls.map((call) => call.method),
      containsAllInOrder(<String>[
        'getRuntimeStatus',
        'getRuntimeStatus',
        'getAccessStatus',
        'getRuntimeStatus',
        'requestAccess',
      ]),
    );
  });

  test('parses active records and normalizes native byte lists', () async {
    const platform = MethodChannelWindowsNotificationListener();

    final active = await platform.listActiveNotifications();
    expect(active, hasLength(1));
    expect(active.single['userNotificationId'], 812);
    expect(active.single['iconBytes'], isA<List<int>>());
    expect(active.single['iconBytes'], orderedEquals(<int>[1, 2, 3]));

    await platform.start();
    await platform.stop();
    expect(
        calls.map((call) => call.method),
        containsAll(<String>[
          'start',
          'stop',
        ]));
  });

  test('reports unsupported without invoking native methods', () async {
    MethodChannelWindowsNotificationListener.debugIsWindowsOverride = false;
    const platform = MethodChannelWindowsNotificationListener();

    final status = await platform.getRuntimeStatus();
    expect(status.supported, isFalse);
    expect(await platform.getAccessStatus(), 'unsupported');
    expect(await platform.requestAccess(), 'unsupported');
    expect(await platform.listActiveNotifications(), isEmpty);
    expect(calls, isEmpty);
  });

  test('facade maps unpackaged runtime to the canonical state', () async {
    WindowsNotificationListener.platform = _FakePlatform(
      runtime: const WindowsNotificationListenerRuntimeStatus(
        supported: true,
        hasPackageIdentity: false,
      ),
    );

    final status = await WindowsNotificationListener.getStatus();
    expect(status.accessState, WindowsNotificationAccessState.unpackaged);
    expect(status.hasPackageIdentity, isFalse);

    WindowsNotificationListener.platform =
        const MethodChannelWindowsNotificationListener();
  });
}

class _FakePlatform implements WindowsNotificationListenerPlatform {
  _FakePlatform({required this.runtime});

  final WindowsNotificationListenerRuntimeStatus runtime;

  @override
  bool get isSupported => true;

  @override
  Future<WindowsNotificationListenerRuntimeStatus> getRuntimeStatus() async =>
      runtime;

  @override
  Future<String> getAccessStatus() async => 'allowed';

  @override
  Future<String> requestAccess() async => 'allowed';

  @override
  Future<List<Map<String, dynamic>>> listActiveNotifications() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<bool> start() async => true;

  @override
  Future<void> stop() async {}

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
}
