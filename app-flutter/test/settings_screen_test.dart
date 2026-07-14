import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_flutter/screens/settings_screen.dart';
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';

class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  late MockJsonRpcClient mockClient;

  final mockDeviceInfo = {
    'deviceId': 'rift-test-device-id',
    'displayName': 'Test Device',
    'fingerprint': 'TEST-FINGERPRINT',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockClient = MockJsonRpcClient();
    when(() => mockClient.getDeviceInfo())
        .thenAnswer((_) async => mockDeviceInfo);
  });

  testWidgets('SettingsScreen shows UI elements and device info',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await tester.pumpAndSettle();

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

    await tester.pumpAndSettle();

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

    await tester.pumpAndSettle();
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

    await tester.pumpAndSettle();

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

    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Clipboard received notifications'),
      200,
    );
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPrefs.clipboardNotificationsEnabled), isTrue);
  });
}
