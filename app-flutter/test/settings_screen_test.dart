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

  testWidgets('SettingsScreen handles UnimplementedError (Android/Windows stub)', (WidgetTester tester) async {
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
}
