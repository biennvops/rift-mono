import 'package:rift/src/platform/android_shell.dart';
import 'package:rift/src/platform/linux_notifications.dart';
import 'package:rift/src/platform/macos_notifications.dart';
import 'package:rift/src/platform/windows_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const androidChannel = MethodChannel('rift/android/shell');
  const linuxChannel = MethodChannel('rift/linux/notifications');
  const windowsChannel = MethodChannel('rift/windows/shell');
  final androidCalls = <MethodCall>[];
  final linuxCalls = <MethodCall>[];
  final windowsCalls = <MethodCall>[];

  setUp(() {
    AndroidShell.debugIsAndroidOverride = true;
    LinuxNotifications.debugIsLinuxOverride = true;
    WindowsShell.debugIsWindowsOverride = true;
    androidCalls.clear();
    linuxCalls.clear();
    windowsCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, (call) async {
      androidCalls.add(call);
      return true;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(linuxChannel, (call) async {
      linuxCalls.add(call);
      return true;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowsChannel, (call) async {
      windowsCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    AndroidShell.debugIsAndroidOverride = null;
    LinuxNotifications.debugIsLinuxOverride = null;
    WindowsShell.debugIsWindowsOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(linuxChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowsChannel, null);
  });

  test('LinuxNotifications forwards payload and native actions', () async {
    final shown = await LinuxNotifications.show(
      title: 'Mirror',
      body: 'Remote ping',
      route: 'history.notifications',
      payload: const <String, Object?>{
        'notificationId': 'notif-1',
      },
      actions: const <DesktopNotificationAction>[
        DesktopNotificationAction(id: 'open', title: 'Open'),
        DesktopNotificationAction(id: 'dismiss', title: 'Dismiss'),
      ],
      notificationKey: 'rift.mirror.v1.linux',
    );

    expect(shown, isTrue);
    expect(linuxCalls.single.arguments, <String, Object?>{
      'title': 'Mirror',
      'body': 'Remote ping',
      'route': 'history.notifications',
      'notificationKey': 'rift.mirror.v1.linux',
      'payload': const <String, Object?>{
        'notificationId': 'notif-1',
      },
      'actions': const <Map<String, String>>[
        <String, String>{'id': 'open', 'title': 'Open'},
        <String, String>{'id': 'dismiss', 'title': 'Dismiss'},
      ],
    });
  });

  test('WindowsShell forwards mirrored notification payload unchanged',
      () async {
    final shown = await WindowsShell.showNotification(
      title: 'Mirror',
      body: 'Remote ping',
      route: 'history.notifications',
      payload: const <String, Object?>{
        'notificationId': 'notif-2',
        'sourceDeviceId': 'rift-peer-2',
      },
      notificationKey: 'rift.mirror.v1.windows',
    );

    expect(shown, isTrue);
    expect(windowsCalls.single.arguments, <String, Object?>{
      'title': 'Mirror',
      'body': 'Remote ping',
      'route': 'history.notifications',
      'notificationKey': 'rift.mirror.v1.windows',
      'payload': const <String, Object?>{
        'notificationId': 'notif-2',
        'sourceDeviceId': 'rift-peer-2',
      },
    });
  });

  test('desktop bridges forward binary icon bytes', () async {
    final iconBytes = Uint8List.fromList([1, 2, 3]);

    await AndroidShell.showNotification(
      title: 'Android',
      body: 'Mirror',
      route: 'history.notifications',
      iconBytes: iconBytes,
    );
    await LinuxNotifications.show(
      title: 'Linux',
      body: 'Mirror',
      route: 'history.notifications',
      iconBytes: iconBytes,
    );
    await WindowsShell.showNotification(
      title: 'Windows',
      body: 'Mirror',
      route: 'history.notifications',
      iconBytes: iconBytes,
    );

    expect(androidCalls.single.arguments['iconBytes'], iconBytes);
    expect(linuxCalls.single.arguments['iconBytes'], iconBytes);
    expect(windowsCalls.single.arguments['iconBytes'], iconBytes);
  });

  test('AndroidShell forwards foreground sync status payload', () async {
    final shown = await AndroidShell.updateForegroundSyncStatus(
      runtimeState: 'ready',
      trustedPeerCount: 3,
      connectedPeerCount: 2,
      connectedPeerNames: const ['Fedora Workstation', 'MacBook Pro'],
    );

    expect(shown, isTrue);
    expect(androidCalls.single.method, 'updateForegroundSyncStatus');
    expect(androidCalls.single.arguments, <String, Object?>{
      'runtimeState': 'ready',
      'trustedPeerCount': 3,
      'connectedPeerCount': 2,
      'connectedPeerNames': const ['Fedora Workstation', 'MacBook Pro'],
    });
  });

  test('desktop bridges forward keyed clear requests', () async {
    expect(await LinuxNotifications.clearNotification('linux-key'), isTrue);
    expect(await WindowsShell.clearNotification('windows-key'), isTrue);

    expect(linuxCalls.single.method, 'clearNotification');
    expect(linuxCalls.single.arguments, {'notificationKey': 'linux-key'});
    expect(windowsCalls.single.method, 'clearNotification');
    expect(windowsCalls.single.arguments, {'notificationKey': 'windows-key'});
  });
}
