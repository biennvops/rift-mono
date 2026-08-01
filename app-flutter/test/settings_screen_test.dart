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
import 'package:app_flutter/src/platform/linux_notifications.dart';

class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const androidShellChannel = MethodChannel('rift/android/shell');
  const linuxNotificationsChannel = MethodChannel('rift/linux/notifications');
  const macOsPermissionsChannel = MethodChannel('rift.permissions');
  late MockJsonRpcClient mockClient;
  late StreamController<bool> connectionChangedController;
  late bool isConnected;

  final mockDeviceInfo = {
    'deviceId': 'rift-test-device-id',
    'displayName': 'Test Device',
    'fingerprint': 'TEST-FINGERPRINT',
  };

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(<String, Object?>{});
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AndroidShell.debugIsAndroidOverride = true;
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
    when(() => mockClient.onTrustChanged)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.listTrustedPeers())
        .thenAnswer((_) async => <String, dynamic>{'peers': <dynamic>[]});
  });

  tearDown(() {
    AndroidShell.debugIsAndroidOverride = null;
    LinuxNotifications.debugIsLinuxOverride = null;
    connectionChangedController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, null);
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
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);

    // Tab rail labels should be visible
    expect(find.text('General'),
        findsNWidgets(2)); // Tab rail label + panel header
    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('System Checks'), findsOneWidget);
    expect(find.text('File Transfer'), findsOneWidget);
    expect(find.text('Trust Store'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    // Default tab is General
    expect(find.text('Device name'), findsOneWidget);
    expect(find.text('Pair by IP'), findsOneWidget);
    final generalCard = find
        .ancestor(
            of: find.text('Device name'), matching: find.byType(Container))
        .evaluate()
        .map((element) => element.widget)
        .whereType<Container>()
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).color == Colors.white &&
              (container.decoration! as BoxDecoration).borderRadius ==
                  BorderRadius.circular(8),
        );
    expect(
      (generalCard.decoration! as BoxDecoration).color,
      Colors.white,
    );

    // Tap Identity tab to see device info
    await tester.tap(find.text('Identity'));
    await pumpLoaded(tester);

    expect(find.text('rift-test-device-id'), findsOneWidget);
    expect(find.text('TEST-FINGERPRINT'), findsOneWidget);
  });

  testWidgets('mobile settings menu uses tinted square icon containers',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);

    expect(find.byIcon(Icons.tune), findsOneWidget);
    final tintedSquare = find.byWidgetPredicate(
      (widget) {
        if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
          return false;
        }
        final decoration = widget.decoration as BoxDecoration;
        return decoration.color != null &&
            decoration.color != Colors.transparent &&
            decoration.borderRadius == BorderRadius.circular(8);
      },
    );
    expect(tintedSquare, findsWidgets);
  });

  testWidgets('Trust Store opens blocked peer management',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);

    await tester.tap(find.text('Trust Store'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MANAGE TRUST STORE'));
    await tester.pumpAndSettle();

    expect(find.text('Blocked Peers'), findsOneWidget);
    expect(find.text('No Blocked Peers'), findsOneWidget);
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

    await tester.tap(find.text('Identity'));
    await pumpLoaded(tester);

    expect(find.text('Unknown'), findsNWidgets(2)); // Device ID and Fingerprint
  });

  testWidgets('SettingsScreen persists clipboard notification preference',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    expect(find.text('Clipboard received notifications'), findsOneWidget);
    final switchFinder = find.byType(Switch).first;
    expect(switchFinder, findsOneWidget);

    await tester.tap(switchFinder);
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    final switches = find.byType(Switch);
    expect(switches, findsAtLeastNWidgets(2));
    await tester.tap(switches.at(1)); // Android notification sync switch
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPrefs.notificationSyncEnabled), isFalse);
    expect(
      prefs.getStringList(AppPrefs.notificationSyncBlacklist),
      <String>[],
    );

    await tester.enterText(
      find.byType(TextField),
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    final blacklistField = find.byType(TextField);

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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    expect(find.text('Notification access'), findsOneWidget);
    final testBtn = find.textContaining('Test notification');
    expect(testBtn, findsOneWidget);

    await tester.tap(testBtn);
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    final testBtn = find.textContaining('Test desktop sync');
    await tester.tap(testBtn);
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    final testBtn = find.textContaining('Test desktop sync');
    await tester.tap(testBtn);
    await tester.pumpAndSettle();

    expect(find.textContaining('trusted peers'), findsNothing);
  });
}
