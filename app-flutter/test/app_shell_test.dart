import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/file_transfer/send_queue_controller.dart';
import 'package:app_flutter/screens/settings_screen.dart';
import 'package:app_flutter/src/platform/android_shell.dart';
import 'package:app_flutter/src/platform/ios_notifications.dart';
import 'package:app_flutter/src/platform/notification_route.dart';
import 'package:app_flutter/src/platform/windows_shell.dart';
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
  Stream<Map<String, dynamic>> get onFileTransferProgress =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onFileTransferCompleted =>
      const Stream.empty();

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
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockJsonRpcClient mockClient;
  late StreamController<bool> connectionChangedController;
  late StreamController<Map<String, dynamic>> notificationPostedController;
  late StreamController<Map<String, dynamic>> notificationUpdatedController;
  late StreamController<Map<String, dynamic>> notificationRemovedController;
  late StreamController<Map<String, dynamic>>
      notificationActionRequestController;
  late bool isConnected;
  final macOsCalls = <MethodCall>[];

  Future<void> dispatchPlatformMethodCall(
      String channel, MethodCall call) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final codec = const StandardMethodCodec();
    ByteData? reply;
    await messenger.handlePlatformMessage(
      channel,
      codec.encodeMethodCall(call),
      (data) => reply = data,
    );
    if (reply != null) {
      codec.decodeEnvelope(reply!);
    }
  }

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
    setMacOSNotificationBridgeOverride(true);
    IOSNotifications.debugIsIOSOverride = false;
    WindowsShell.debugIsWindowsOverride = null;
    mockClient = MockJsonRpcClient();
    connectionChangedController = StreamController<bool>.broadcast();
    notificationPostedController =
        StreamController<Map<String, dynamic>>.broadcast();
    notificationUpdatedController =
        StreamController<Map<String, dynamic>>.broadcast();
    notificationRemovedController =
        StreamController<Map<String, dynamic>>.broadcast();
    notificationActionRequestController =
        StreamController<Map<String, dynamic>>.broadcast();
    isConnected = true;
    macOsCalls.clear();

    // Default mock behavior
    when(() => mockClient.isConnected).thenAnswer((_) => isConnected);
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
    when(() => mockClient.onNotificationPosted)
        .thenAnswer((_) => notificationPostedController.stream);
    when(() => mockClient.onNotificationUpdated)
        .thenAnswer((_) => notificationUpdatedController.stream);
    when(() => mockClient.onNotificationRemoved)
        .thenAnswer((_) => notificationRemovedController.stream);
    when(() => mockClient.onNotificationActionResult)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onNotificationActionRequest)
        .thenAnswer((_) => notificationActionRequestController.stream);
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
        .thenAnswer((_) => connectionChangedController.stream);
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
      () => mockClient.performNotificationAction(
        sourceDeviceId: any(named: 'sourceDeviceId'),
        notificationId: any(named: 'notificationId'),
        action: any(named: 'action'),
      ),
    ).thenAnswer((_) async => <String, Object?>{'success': true});
    when(() => mockClient.reportLocalNotificationActionHandled(
          requestId: any(named: 'requestId'),
          success: any(named: 'success'),
          failureReason: any(named: 'failureReason'),
          message: any(named: 'message'),
        )).thenAnswer((_) async => <String, Object?>{'success': true});
    when(() => mockClient.connect()).thenAnswer((_) async {});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('rift.permissions'),
      (call) async {
        macOsCalls.add(call);
        switch (call.method) {
          case 'notification.show':
            return true;
          case 'share.consumePendingItems':
            return null;
          case 'notification.getStatus':
            return 'authorized';
          case 'notification.request':
            return true;
        }
        return null;
      },
    );
  });

  tearDown(() {
    connectionChangedController.close();
    notificationPostedController.close();
    notificationUpdatedController.close();
    notificationRemovedController.close();
    notificationActionRequestController.close();
    AndroidShell.debugIsAndroidOverride = null;
    setMacOSNotificationBridgeOverride(null);
    IOSNotifications.debugIsIOSOverride = null;
    WindowsShell.debugIsWindowsOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('rift.permissions'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('rift/ios/notifications'),
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

  testWidgets(
      'HomeScreen auto-opens PairingScreen for incoming pairing request',
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
    setMacOSNotificationBridgeOverride(true);
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

  testWidgets('RiftApp reapplies saved notification sync policy on reconnect',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      AppPrefs.notificationSyncEnabled: false,
      AppPrefs.notificationSyncBlacklist: ['com.bank.example'],
    });
    isConnected = false;

    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    verifyNever(
      () => mockClient.updateNotificationSyncPolicy(
        enabled: any(named: 'enabled'),
        blacklistedPackages: any(named: 'blacklistedPackages'),
      ),
    );

    isConnected = true;
    connectionChangedController.add(true);
    await tester.pump();
    await tester.pump();

    verify(
      () => mockClient.updateNotificationSyncPolicy(
        enabled: false,
        blacklistedPackages: ['com.bank.example'],
      ),
    ).called(1);
  });

  testWidgets(
      'mirrored notification post emits desktop payload with route and notification id',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();
    clearInteractions(mockClient);

    notificationPostedController.add(<String, dynamic>{
      'notificationId': 'notif-123',
      'sourceDeviceId': 'rift-peer-1',
      'appName': 'Messages',
      'title': 'Alice',
      'bodyPreview': 'Ping',
      'isOpenable': true,
      'isDismissible': true,
    });
    await tester.pump();

    final showCall =
        macOsCalls.lastWhere((call) => call.method == 'notification.show');
    final arguments = Map<String, Object?>.from(
      showCall.arguments as Map<Object?, Object?>,
    );
    expect(arguments['route'], 'history.notifications');
    expect(arguments['title'], 'Alice');
    expect(arguments['body'], 'rift-peer-1 • Ping');
    expect(arguments['payload'], <String, Object?>{
      'route': 'history.notifications',
      'notificationId': 'notif-123',
      'sourceDeviceId': 'rift-peer-1',
      'appName': 'Messages',
      'isOpenable': true,
      'isDismissible': true,
    });
    expect(arguments['actions'], <Map<String, String>>[
      <String, String>{'id': 'open', 'title': 'Open'},
      <String, String>{'id': 'dismiss', 'title': 'Dismiss'},
    ]);
  });

  testWidgets('iOS consumes launch actions without requesting permission',
      (WidgetTester tester) async {
    setMacOSNotificationBridgeOverride(false);
    IOSNotifications.debugIsIOSOverride = true;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('rift/ios/notifications'),
      (call) async {
        calls.add(call);
        switch (call.method) {
          case 'requestPermission':
          case 'showNotification':
            return true;
          case 'consumeLaunchAction':
            return null;
        }
        return null;
      },
    );

    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    notificationPostedController.add(<String, dynamic>{
      'notificationId': 'notif-ios',
      'sourceDeviceId': 'rift-peer-1',
      'appName': 'Messages',
      'title': 'Alice',
      'bodyPreview': 'Hello iPhone',
      'isOpenable': true,
      'isDismissible': true,
    });
    await tester.pump();

    expect(calls.any((call) => call.method == 'requestPermission'), isFalse);
    expect(calls.any((call) => call.method == 'consumeLaunchAction'), isTrue);
    final showCall =
        calls.lastWhere((call) => call.method == 'showNotification');
    final arguments = Map<String, Object?>.from(
      showCall.arguments as Map<Object?, Object?>,
    );
    expect(arguments['route'], NotificationRoute.historyNotifications);
    expect(arguments['title'], 'Alice');
    expect(arguments['body'], 'rift-peer-1 • Hello iPhone');
  });

  testWidgets(
      'Android notification activation closes settings and opens notification history',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await dispatchPlatformMethodCall(
      'rift/android/shell',
      const MethodCall('notificationActivated', <String, Object?>{
        'route': 'history.notifications',
      }),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Notifications'), findsWidgets);
  });

  testWidgets(
      'Android executes incoming notification action requests and reports results',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('rift/android/shell'),
      (call) async {
        if (call.method == 'performLocalNotificationAction') {
          expect(call.arguments, {
            'notificationId': 'android-notif-1',
            'action': 'dismiss',
          });
          return <String, Object?>{'success': true};
        }
        return null;
      },
    );
    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();
    clearInteractions(mockClient);

    notificationActionRequestController.add({
      'requestId': 'request-1',
      'notificationId': 'android-notif-1',
      'sourceDeviceId': 'rift-android',
      'requestingDeviceId': 'rift-desktop',
      'action': 'dismiss',
    });
    await tester.pump();

    verify(
      () => mockClient.reportLocalNotificationActionHandled(
        requestId: 'request-1',
        success: true,
        failureReason: null,
        message: null,
      ),
    ).called(1);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('rift/android/shell'),
      null,
    );
  });

  testWidgets(
      'explicit mirrored notification actions call performNotificationAction',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();
    clearInteractions(mockClient);

    await dispatchPlatformMethodCall(
      'rift.permissions',
      const MethodCall('notificationActivated', <String, Object?>{
        'route': 'history.notifications',
        'sourceDeviceId': 'rift-android',
        'notificationId': 'notif-321',
        'notificationAction': 'open',
      }),
    );
    await tester.pump();

    verify(
      () => mockClient.performNotificationAction(
        sourceDeviceId: 'rift-android',
        notificationId: 'notif-321',
        action: 'open',
      ),
    ).called(1);
  });

  testWidgets(
      'disconnected mirrored notification actions are queued and flushed on reconnect',
      (WidgetTester tester) async {
    isConnected = false;

    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();
    clearInteractions(mockClient);

    await dispatchPlatformMethodCall(
      'rift.permissions',
      const MethodCall('notificationActivated', <String, Object?>{
        'route': 'history.notifications',
        'sourceDeviceId': 'rift-android',
        'notificationId': 'notif-queued',
        'notificationAction': 'dismiss',
      }),
    );
    await tester.pump();

    verifyNever(
      () => mockClient.performNotificationAction(
        sourceDeviceId: any(named: 'sourceDeviceId'),
        notificationId: any(named: 'notificationId'),
        action: any(named: 'action'),
      ),
    );
    verify(() => mockClient.connect()).called(1);

    isConnected = true;
    connectionChangedController.add(true);
    await tester.pump();
    await tester.pump();

    verify(
      () => mockClient.performNotificationAction(
        sourceDeviceId: 'rift-android',
        notificationId: 'notif-queued',
        action: 'dismiss',
      ),
    ).called(1);
  });

  testWidgets(
      'mirrored notification updates and removals do not emit duplicate native popups',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildRiftApp(mockClient));
    await tester.pump();
    clearInteractions(mockClient);

    notificationPostedController.add(<String, dynamic>{
      'notificationId': 'notif-dup',
      'title': 'Posted',
    });
    await tester.pump();
    final showCountAfterPost =
        macOsCalls.where((call) => call.method == 'notification.show').length;

    notificationUpdatedController.add(<String, dynamic>{
      'notificationId': 'notif-dup',
      'title': 'Updated',
    });
    notificationRemovedController.add(<String, dynamic>{
      'notificationId': 'notif-dup',
    });
    await tester.pump();

    final showCountFinal =
        macOsCalls.where((call) => call.method == 'notification.show').length;
    expect(showCountAfterPost, 1);
    expect(showCountFinal, 1);
  });
}
