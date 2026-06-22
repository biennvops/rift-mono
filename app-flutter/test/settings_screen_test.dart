import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/screens/settings_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/constants.dart';

class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  late MockJsonRpcClient mockClient;

  final mockDeviceInfo = {
    'deviceId': 'rift-test-device-id',
    'fingerprint': 'TEST-FINGERPRINT',
    'implementationId': 'riftd-test/0.1.0',
    'protocolVersion': '0.1-test',
  };

  setUp(() {
    mockClient = MockJsonRpcClient();
    when(() => mockClient.getDeviceInfo())
        .thenAnswer((_) async => mockDeviceInfo);
  });

  testWidgets('SettingsScreen shows title and device info', (WidgetTester tester) async {
    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    // Wait for the post frame callback and FutureBuilder to complete
    await tester.pumpAndSettle();

    // Title should be visible
    expect(find.text(AppStrings.settingsTitle), findsOneWidget);

    // Info from mock should be visible
    expect(find.text('rift-test-device-id'), findsOneWidget);
    expect(find.text('TEST-FINGERPRINT'), findsOneWidget);
    expect(find.text('riftd-test/0.1.0'), findsOneWidget);
    expect(find.text('0.1-test'), findsOneWidget);
  });

  testWidgets('SettingsScreen handles unavailable platform feature errors', (WidgetTester tester) async {
    when(() => mockClient.getDeviceInfo()).thenAnswer((_) => Future.error(UnimplementedError('Stub')));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Feature not available on this platform'), findsOneWidget);
  });

  testWidgets('SettingsScreen shows error message for generic error', (WidgetTester tester) async {
    when(() => mockClient.getDeviceInfo()).thenAnswer((_) => Future.error(Exception('Generic failure')));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.textContaining('Error fetching device info:'), findsOneWidget);
    expect(find.textContaining('Generic failure'), findsOneWidget);
  });

  testWidgets('SettingsScreen shows loading spinner while waiting', (WidgetTester tester) async {
    // Create a delayed future to keep it in the waiting state
    when(() => mockClient.getDeviceInfo())
        .thenAnswer((_) => Future.delayed(const Duration(seconds: 1), () => mockDeviceInfo));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await tester.pump(); // Pump once to trigger FutureBuilder, but don't settle yet

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    
    await tester.pumpAndSettle(); // Finish the future to clean up
  });

  testWidgets('SettingsScreen shows No data available when data is null', (WidgetTester tester) async {
    when(() => mockClient.getDeviceInfo()).thenAnswer((_) async => null);

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('No data available.'), findsOneWidget);
  });
}
