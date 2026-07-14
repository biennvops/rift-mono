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

class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const androidShellChannel = MethodChannel('rift/android/shell');
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
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockClient = MockJsonRpcClient();
    connectionChangedController = StreamController<bool>.broadcast();
    isConnected = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, (call) async {
      switch (call.method) {
        case 'getNotificationPermissionStatus':
          return 'unknown';
        case 'openNotificationSettings':
          return false;
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
    when(() => mockClient.isConnected).thenAnswer((_) => isConnected);
    when(() => mockClient.onConnectionChanged)
        .thenAnswer((_) => connectionChangedController.stream);
  });

  tearDown(() {
    connectionChangedController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, null);
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
      find.text('Notification status unavailable on this platform'),
      200,
    );
    expect(
      find.text('Notification status unavailable on this platform'),
      findsOneWidget,
    );
    // Info from mock should be visible
    expect(find.text('rift-test-device-id'), findsOneWidget);
    expect(find.text('TEST-FINGERPRINT'), findsOneWidget);
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

    await tester.enterText(
      find.widgetWithText(TextField, 'Notification blacklist'),
      'com.bank.example',
    );
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPrefs.notificationSyncEnabled), isFalse);
    expect(
      prefs.getStringList(AppPrefs.notificationSyncBlacklist),
      ['com.bank.example'],
    );
  });

}
