import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/main.dart'; // Or wherever RiftApp is defined
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/ipc/ipc_transport.dart';
import 'package:stream_channel/stream_channel.dart';

// Create a Mock for the JsonRpcRiftClient
class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

class FakeTransport implements IpcTransport {
  @override
  Future<StreamChannel<String>> connect() async =>
      StreamChannel(Stream.empty(), StreamController<String>().sink);

  @override
  Future<void> disconnect() async {}
}

class FakeShellJsonRpcClient extends JsonRpcRiftClient {
  FakeShellJsonRpcClient() : super(FakeTransport());

  final _pairingRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  String? approvedDeviceId;
  String? approvedFingerprint;

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onPairingRequest =>
      _pairingRequestController.stream;

  @override
  Future<dynamic> listTrustedPeers() async => {
        'peers': [
          {
            'deviceId': 'rift-peer-1',
            'presence': 'online',
            'trustState': 'trusted',
          },
        ],
      };

  @override
  Future<dynamic> listDiscoveredPeers() async => {
        'peers': const [],
        'isDiscovering': true,
      };

  Future<void> emitPairingRequest(Map<String, dynamic> event) async {
    _pairingRequestController.add(event);
  }

  @override
  Future<dynamic> approvePairing(String deviceId, String fingerprint) async {
    approvedDeviceId = deviceId;
    approvedFingerprint = fingerprint;
    return {
      'trustedDeviceId': deviceId,
      'persistedAt': '2026-06-24T00:00:00Z',
    };
  }
}

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
    when(() => mockClient.onPairingRequest)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.getDeviceInfo())
        .thenAnswer((_) async => mockDeviceInfo);
    when(() => mockClient.listTrustedPeers()).thenAnswer(
      (_) async => {
        'peers': [
          {
            'deviceId': 'rift-peer-1',
            'presence': 'online',
            'trustState': 'trusted',
          },
          {
            'deviceId': 'rift-peer-2',
            'presence': 'offline',
            'trustState': 'trusted',
          },
        ],
      },
    );
    when(() => mockClient.listDiscoveredPeers()).thenAnswer(
      (_) async => {
        'peers': [
          {
            'deviceId': 'rift-peer-3',
            'trustState': 'discovered',
          },
        ],
        'isDiscovering': true,
      },
    );
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
    expect(find.text(AppStrings.daemonConnected), findsOneWidget);
    expect(find.text('2 trusted  •  1 online  •  1 discovered  •  discovery running'),
        findsOneWidget);
    expect(find.text(AppStrings.openTrustedDevices), findsOneWidget);
    expect(find.text(AppStrings.openEventLog), findsOneWidget);
    expect(find.text(AppStrings.openSettings), findsOneWidget);
  });

  test('MockClient getDeviceInfo test', () async {
    // Test the mock setup directly
    expect(mockClient.isConnected, isTrue);
    final result = await mockClient.getDeviceInfo();
    expect(result, equals(mockDeviceInfo));
  });

  testWidgets('HomeScreen auto-opens PairingScreen for incoming pairing request',
      (WidgetTester tester) async {
    final client = FakeShellJsonRpcClient();

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const RiftApp(),
      ),
    );
    await tester.pumpAndSettle();

    await client.emitPairingRequest({
      'deviceId': 'rift-linux-peer',
      'displayName': 'Linux Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.pairingTitle), findsOneWidget);
    expect(find.text('Linux Laptop'), findsOneWidget);
    expect(find.text('Incoming pairing request'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);

    final approveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Approve'),
    );
    expect(approveButton.onPressed, isNotNull);
  });

  testWidgets('Incoming pairing request from app shell can be approved',
      (WidgetTester tester) async {
    final client = FakeShellJsonRpcClient();

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const RiftApp(),
      ),
    );
    await tester.pumpAndSettle();

    await client.emitPairingRequest({
      'deviceId': 'rift-linux-peer',
      'displayName': 'Linux Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(client.approvedDeviceId, 'rift-linux-peer');
    expect(
      client.approvedFingerprint,
      'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    );
    expect(find.text('Approval sent. Waiting for completion'), findsOneWidget);
  });
}
