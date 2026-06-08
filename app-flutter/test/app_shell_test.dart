import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/main.dart'; // Or wherever RiftApp is defined
import 'package:app_flutter/constants.dart';

// Create a Mock for the JsonRpcRiftClient
class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  late MockJsonRpcClient mockClient;

  final mockDeviceInfo = {
    'deviceId': 'rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq',
    'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
    'implementationId': 'riftd-cs/0.1.0',
    'protocolVersion': '0.1-draft',
    'capabilities': [
      {'name': 'clipboard.offer_fetch', 'version': 1}
    ]
  };

  setUp(() {
    mockClient = MockJsonRpcClient();

    // Default mock behavior
    when(() => mockClient.isConnected).thenReturn(true);
    when(() => mockClient.getDeviceInfo())
        .thenAnswer((_) async => mockDeviceInfo);
  });

  testWidgets('App shell boots up and displays main navigation',
      (WidgetTester tester) async {
    // Inject mockClient via Provider
    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const RiftApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify main components are present
    expect(find.text(AppStrings.appTitle), findsOneWidget);

    // Future expansion:
    // Verify IPC connection state icon or text if we add it to the shell.
  });

  testWidgets('MockClient getDeviceInfo test', (WidgetTester tester) async {
    // Test the mock setup directly
    expect(mockClient.isConnected, isTrue);
    final result = await mockClient.getDeviceInfo();
    expect(result, equals(mockDeviceInfo));
  });
}
