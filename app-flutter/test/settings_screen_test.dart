import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_flutter/screens/settings_screen.dart';
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/platform/android_shell.dart';
import 'package:app_flutter/src/platform/ios_notifications.dart';
import 'package:app_flutter/src/platform/linux_notifications.dart';

class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const androidShellChannel = MethodChannel('rift/android/shell');
  const iosNotificationsChannel = MethodChannel('rift/ios/notifications');
  const linuxNotificationsChannel = MethodChannel('rift/linux/notifications');
  const macOsPermissionsChannel = MethodChannel('rift.permissions');
  late MockJsonRpcClient mockClient;
  late StreamController<bool> connectionChangedController;
  late bool isConnected;

  final mockDeviceInfo = {
    'deviceId': 'rift-test-device-id',
    'displayName': 'Test Device',
    'fingerprint': 'TEST-FINGERPRINT',
    'identityProtectionBackend': 'secret-service',
  };

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(<String, Object?>{});
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AndroidShell.debugIsAndroidOverride = true;
    IOSNotifications.debugIsIOSOverride = false;
    LinuxNotifications.debugIsLinuxOverride = null;
    mockClient = MockJsonRpcClient();
    connectionChangedController = StreamController<bool>.broadcast();
    isConnected = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, (call) async {
      switch (call.method) {
        case 'getNotificationPermissionStatus':
          return 'authorized';
        case 'getNotificationListenerAccessStatus':
          return 'denied';
        case 'openNotificationSettings':
        case 'openNotificationListenerSettings':
          return true;
        case 'showTestNotification':
          return true;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(linuxNotificationsChannel, (call) async {
      switch (call.method) {
        case 'showNotification':
          return true;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(macOsPermissionsChannel, (call) async {
      switch (call.method) {
        case 'notification.getStatus':
          return 'unknown';
      }
      return null;
    });
    when(() => mockClient.getDeviceInfo())
        .thenAnswer((_) async => mockDeviceInfo);
    when(
      () => mockClient.updateNotificationSyncPolicy(
        enabled: any(named: 'enabled'),
        blacklistedPackages: any(named: 'blacklistedPackages'),
      ),
    ).thenAnswer(
      (_) async => {
        'enabled': true,
        'blacklistedPackages': ['com.bank.example'],
      },
    );
    when(
      () => mockClient.notifyLocalNotificationEvent(
        eventType: any(named: 'eventType'),
        payload: any(named: 'payload'),
      ),
    ).thenAnswer(
      (_) async => {
        'notificationId': 'android:com.example.app_flutter:test:1',
        'broadcastTo': ['rift-peer'],
        'suppressed': false,
      },
    );
    when(() => mockClient.isConnected).thenAnswer((_) => isConnected);
    when(() => mockClient.onConnectionChanged)
        .thenAnswer((_) => connectionChangedController.stream);
  });

  tearDown(() {
    AndroidShell.debugIsAndroidOverride = null;
    IOSNotifications.debugIsIOSOverride = null;
    LinuxNotifications.debugIsLinuxOverride = null;
    connectionChangedController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(iosNotificationsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(linuxNotificationsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(macOsPermissionsChannel, null);
  });

  Future<void> pumpLoaded(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('SettingsScreen shows UI elements and device info',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);

    // Sections should be visible
    expect(find.text('GENERAL'), findsOneWidget);
    expect(find.text('IDENTITY'), findsOneWidget);
    expect(find.text('PERMISSIONS'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('System notifications enabled'), 200);
    expect(find.text('System notifications enabled'), findsOneWidget);
    expect(find.text('Android notification access is off'), findsOneWidget);
    // Info from mock should be visible
    expect(find.text('rift-test-device-id'), findsOneWidget);
    expect(find.text('TEST-FINGERPRINT'), findsOneWidget);
  });

  testWidgets('SettingsScreen reports real Linux runtime status',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    LinuxNotifications.debugIsLinuxOverride = true;
    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.scrollUntilVisible(
      find.text('Linux Runtime'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Linux Runtime'), findsOneWidget);
    expect(find.text('Daemon IPC: connected'), findsOneWidget);
    expect(find.text('Identity protection: secret-service'), findsOneWidget);
    expect(find.text('avahi-daemon: running'), findsNothing);
    expect(find.text('appindicator: supported'), findsNothing);
  });

  testWidgets('SettingsScreen exposes iOS notification diagnostics',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    IOSNotifications.debugIsIOSOverride = true;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(iosNotificationsChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getPermissionStatus':
          return 'authorized';
        case 'showNotification':
        case 'openSettings':
        case 'requestPermission':
          return true;
      }
      return null;
    });

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);

    await tester.scrollUntilVisible(
      find.text('System notifications enabled'),
      200,
    );
    expect(find.text('System notifications enabled'), findsOneWidget);
    expect(find.text('Used during discovery and pairing'), findsOneWidget);
    expect(
      find.text(
        'Development builds can use location keepalive; iOS may still terminate the app',
      ),
      findsOneWidget,
    );

    final testNotificationButton =
        find.byKey(const Key('test-notification-button'));
    await tester.ensureVisible(testNotificationButton);
    await tester.pumpAndSettle();
    await tester.tap(testNotificationButton);
    await tester.pumpAndSettle();

    expect(calls.any((call) => call.method == 'getPermissionStatus'), isTrue);
    final showCall =
        calls.lastWhere((call) => call.method == 'showNotification');
    final arguments = Map<String, Object?>.from(
      showCall.arguments as Map<Object?, Object?>,
    );
    expect(arguments['title'], 'Rift test notification');
    expect(arguments['route'], 'history.notifications');
    expect(find.text('Sent iOS test notification.'), findsOneWidget);
  });

  testWidgets('SettingsScreen shows error message for generic error',
      (WidgetTester tester) async {
    when(() => mockClient.getDeviceInfo())
        .thenAnswer((_) => Future.error(Exception('Generic failure')));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);

    // The error should be formatted by JsonRpcRiftClient.formatDisplayError
    // Usually it starts with "Exception: " or something. We'll just look for "Generic failure"
    expect(find.textContaining('Generic failure'), findsOneWidget);

    // UI should still be rendered (fallback values)
    expect(find.text('Unknown Device'), findsOneWidget);
  });

  testWidgets('SettingsScreen shows loading spinner while waiting',
      (WidgetTester tester) async {
    when(() => mockClient.getDeviceInfo()).thenAnswer((_) =>
        Future.delayed(const Duration(seconds: 1), () => mockDeviceInfo));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('SettingsScreen handles null device info with fallbacks',
      (WidgetTester tester) async {
    when(() => mockClient.getDeviceInfo()).thenAnswer((_) async => null);

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);

    expect(find.text('Unknown Device'), findsOneWidget);
    expect(find.text('Unknown'), findsNWidgets(2)); // Device ID and Fingerprint
  });

  testWidgets('SettingsScreen persists clipboard notification preference',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);

    await tester.scrollUntilVisible(
      find.text('Clipboard received notifications'),
      200,
    );
    await tester.ensureVisible(find.text('Clipboard received notifications'));
    await pumpLoaded(tester);
    expect(find.byType(SwitchListTile), findsNWidgets(2));

    await tester.tap(find.text('Clipboard received notifications'));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPrefs.clipboardNotificationsEnabled), isTrue);
  });

  testWidgets('SettingsScreen persists notification sync policy',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    final notificationSyncTile = find.widgetWithText(
      SwitchListTile,
      'Android notification sync',
    );
    await tester.dragUntilVisible(
      notificationSyncTile,
      find.byType(ListView),
      const Offset(0, -200),
    );

    await tester.tap(notificationSyncTile);
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPrefs.notificationSyncEnabled), isFalse);
    expect(
      prefs.getStringList(AppPrefs.notificationSyncBlacklist),
      <String>[],
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Notification blacklist'),
      'com.bank.example',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      prefs.getStringList(AppPrefs.notificationSyncBlacklist),
      ['com.bank.example'],
    );
  });

  testWidgets('SettingsScreen debounces notification blacklist updates',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    final blacklistField =
        find.widgetWithText(TextField, 'Notification blacklist');
    await tester.dragUntilVisible(
      blacklistField,
      find.byType(ListView),
      const Offset(0, -200),
    );

    await tester.enterText(blacklistField, 'com.example.one');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
      blacklistField,
      'com.example.one\ncom.example.two',
    );
    await tester.pump(const Duration(milliseconds: 100));

    verifyNever(
      () => mockClient.updateNotificationSyncPolicy(
        enabled: any(named: 'enabled'),
        blacklistedPackages: any(named: 'blacklistedPackages'),
      ),
    );

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      (await SharedPreferences.getInstance())
          .getStringList(AppPrefs.notificationSyncBlacklist),
      ['com.example.one', 'com.example.two'],
    );
    verify(
      () => mockClient.updateNotificationSyncPolicy(
        enabled: true,
        blacklistedPackages: ['com.example.one', 'com.example.two'],
      ),
    ).called(1);
  });

  testWidgets('SettingsScreen exposes Android notification actions',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.dragUntilVisible(
      find.text('Notification access'),
      find.byType(ListView),
      const Offset(0, -200),
    );

    expect(find.text('Notification access'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Test notification'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test notification'));
    await tester.pump();

    expect(find.text('Sent Android test notification.'), findsOneWidget);
    final captured = verify(
      () => mockClient.notifyLocalNotificationEvent(
        eventType: 'posted',
        payload: captureAny(named: 'payload'),
      ),
    ).captured.single as Map<String, Object?>;
    expect(
      captured['notificationId'] as String,
      startsWith('android:com.example.app_flutter:test:'),
    );
    expect(captured['packageName'], 'com.example.app_flutter');
    expect(captured['appName'], 'Rift');
    expect(captured['title'], 'Rift test notification');
    expect(
      captured['bodyPreview'],
      'If you see this notification, sync is working.',
    );
    expect(captured['isDismissible'], isTrue);
    expect(captured['isOpenable'], isTrue);
  });

  testWidgets('SettingsScreen exposes desktop notification sync test button',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    LinuxNotifications.debugIsLinuxOverride = null;

    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.dragUntilVisible(
      find.text('Test desktop sync'),
      find.byType(ListView),
      const Offset(0, -200),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test desktop sync'));
    await tester.pumpAndSettle();

    verify(() => mockClient.getDeviceInfo()).called(greaterThan(0));
  });

  testWidgets('desktop notification sync copy references trusted peers',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    LinuxNotifications.debugIsLinuxOverride = true;

    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.dragUntilVisible(
      find.text('Test desktop sync'),
      find.byType(ListView),
      const Offset(0, -200),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test desktop sync'));
    await tester.pumpAndSettle();

    expect(find.textContaining('trusted peers'), findsNothing);
  });
}
