import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/file_transfer/send_queue_controller.dart';
import 'package:app_flutter/src/platform/macos_notifications.dart';
import 'package:app_flutter/main.dart'; // Or wherever RiftApp is defined
import 'package:shared_preferences/shared_preferences.dart';
import 'test_utils/fake_transport.dart';

// Create a Mock for the JsonRpcRiftClient
class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

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
  Stream<Map<String, dynamic>> get onSecurityEvent => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onTrustChanged => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onPairingComplete => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onFileOffer => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onFileTransferProgress => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onFileTransferCompleted => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onFileTransferFailed => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onClipboardOffer => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onClipboardExpired => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onSendQueueChanged =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onSendQueueItemUpdated =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onPeerDiscovered =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onPeerLost =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<dynamic> queryEventLog({
    List<String>? eventTypes,
    List<String>? severities,
    String? peerDeviceId,
    String? since,
    int? limit,
    int? offset,
  }) async {
    return {'events': [], 'total': 0};
  }

  @override
  Stream<Map<String, dynamic>> get onOperationTransition =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<dynamic> listOperations({
    int? limit,
    int? offset,
  }) async {
    return {'operations': [], 'total': 0};
  }

  @override
  Future<dynamic> listClipboardOffers() async => {'offers': []};

  @override
  Future<bool> supportsSendQueue() async => false;

  @override
  Future<dynamic> listSendQueue() async => {'items': []};

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

  Widget buildRiftApp(JsonRpcRiftClient client) {
    return MultiProvider(
      providers: [
        Provider<JsonRpcRiftClient>.value(value: client),
        ChangeNotifierProvider<SendQueueController>(
          create: (_) => SendQueueController(client, false),
        ),
      ],
      child: const RiftApp(hasCompletedOnboarding: true),
    );
  }

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
    SharedPreferences.setMockInitialValues({});
    MacOSNotifications.debugIsMacOSOverride = null;
    mockClient = MockJsonRpcClient();

    // Default mock behavior
    when(() => mockClient.isConnected).thenReturn(true);
    when(() => mockClient.onPairingRequest)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onSecurityEvent)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onTrustChanged)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onPairingComplete)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onPeerDiscovered)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onPeerLost)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.queryEventLog(
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
          eventTypes: any(named: 'eventTypes'),
          severities: any(named: 'severities'),
          peerDeviceId: any(named: 'peerDeviceId'),
          since: any(named: 'since'),
        )).thenAnswer((_) async => {'events': [], 'total': 0});
    when(() => mockClient.onClipboardOffer)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onClipboardExpired)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onFileOffer)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onFileTransferProgress)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onFileTransferCompleted)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onFileTransferFailed)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onSendQueueChanged)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onSendQueueItemUpdated)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onConnectionChanged)
        .thenAnswer((_) => Stream.value(true));
    when(() => mockClient.onOperationTransition)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.listOperations(
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => {'operations': [], 'total': 0});
    when(() => mockClient.listClipboardOffers())
        .thenAnswer((_) async => {'offers': []});
    when(() => mockClient.supportsSendQueue()).thenAnswer((_) async => false);
    when(() => mockClient.listSendQueue())
        .thenAnswer((_) async => {'items': []});
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

  tearDown(() {
    MacOSNotifications.debugIsMacOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('rift.permissions'),
      null,
    );
  });

  testWidgets('App shell boots up and displays main navigation',
      (WidgetTester tester) async {
    // Inject mockClient via Provider
    await tester.pumpWidget(
      buildRiftApp(mockClient),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Events'), findsOneWidget);
    expect(find.text('Ops'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('RIFT'), findsOneWidget);
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
      buildRiftApp(client),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await client.emitPairingRequest({
      'deviceId': 'rift-linux-peer',
      'displayName': 'Linux Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 3));

    expect(find.textContaining('Pairing with Linux Laptop'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);

    final approveButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Approve'),
    );
    expect(approveButton.onPressed, isNotNull);
  });

  testWidgets('Incoming pairing request from app shell can be approved',
      (WidgetTester tester) async {
    final client = FakeShellJsonRpcClient();

    await tester.pumpWidget(
      buildRiftApp(client),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await client.emitPairingRequest({
      'deviceId': 'rift-linux-peer',
      'displayName': 'Linux Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.text('Approve'));
    await tester.pump();

    expect(client.approvedDeviceId, 'rift-linux-peer');
    expect(
      client.approvedFingerprint,
      'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
    );
  });

  testWidgets('App shell consumes pending macOS share payload on startup',
      (WidgetTester tester) async {
    final client = FakeShellJsonRpcClient();
    MacOSNotifications.debugIsMacOSOverride = true;
    final channel = const MethodChannel('rift.permissions');
    var consumedPendingShareItems = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'share.consumePendingItems') {
        consumedPendingShareItems = true;
        return <String, Object?>{
          'route': 'history.send',
          'items': <Map<String, String>>[
            <String, String>{
              'localPath': '/definitely/missing/shared.txt',
              'fileName': 'shared.txt',
              'mediaType': 'text/plain',
            },
          ],
        };
      }
      return null;
    });

    await tester.pumpWidget(buildRiftApp(client));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(consumedPendingShareItems, isTrue);
  });
}
