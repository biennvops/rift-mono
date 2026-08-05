import 'package:rift/src/platform/linux_notifications.dart';
import 'package:rift/src/platform/macos_notifications.dart';
import 'package:rift/src/platform/windows_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const linuxChannel = MethodChannel('rift/linux/notifications');
  const windowsChannel = MethodChannel('rift/windows/shell');
  final linuxCalls = <MethodCall>[];
  final windowsCalls = <MethodCall>[];

  setUp(() {
    LinuxNotifications.debugIsLinuxOverride = true;
    WindowsShell.debugIsWindowsOverride = true;
    linuxCalls.clear();
    windowsCalls.clear();
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
    LinuxNotifications.debugIsLinuxOverride = null;
    WindowsShell.debugIsWindowsOverride = null;
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
    );

    expect(shown, isTrue);
    expect(linuxCalls.single.arguments, <String, Object?>{
      'title': 'Mirror',
      'body': 'Remote ping',
      'route': 'history.notifications',
      'payload': const <String, Object?>{
        'notificationId': 'notif-1',
      },
      'actions': const <Map<String, String>>[
        <String, String>{'id': 'open', 'title': 'Open'},
        <String, String>{'id': 'dismiss', 'title': 'Dismiss'},
      ],
    });
  });

  test('WindowsShell forwards mirrored notification payload unchanged', () async {
    final shown = await WindowsShell.showNotification(
      title: 'Mirror',
      body: 'Remote ping',
      route: 'history.notifications',
      payload: const <String, Object?>{
        'notificationId': 'notif-2',
        'sourceDeviceId': 'rift-peer-2',
      },
    );

    expect(shown, isTrue);
    expect(windowsCalls.single.arguments, <String, Object?>{
      'title': 'Mirror',
      'body': 'Remote ping',
      'route': 'history.notifications',
      'payload': const <String, Object?>{
        'notificationId': 'notif-2',
        'sourceDeviceId': 'rift-peer-2',
      },
    });
  });
}
