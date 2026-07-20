import 'dart:async';

import 'package:app_flutter/screens/onboarding_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/platform/android_shell.dart';
import 'package:app_flutter/src/platform/ios_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class FakeOnboardingClient extends JsonRpcRiftClient {
  FakeOnboardingClient({
    this.localNetworkGranted = true,
  }) : super(FakeTransport());

  bool localNetworkGranted;
  int startDiscoveryCallCount = 0;

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onPeerDiscovered => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onPeerLost => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onTrustChanged => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onPairingRequest => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onPairingComplete => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onSecurityEvent => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onClipboardOffer => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onClipboardExpired => const Stream.empty();

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
  Stream<Map<String, dynamic>> get onOperationTransition =>
      const Stream.empty();

  @override
  Stream<bool> get onConnectionChanged => const Stream.empty();

  @override
  Future<dynamic> startDiscovery() async {
    startDiscoveryCallCount += 1;
    if (!localNetworkGranted) {
      throw Exception('local network denied');
    }
    return {'started': true};
  }
}

void main() {
  const androidShellChannel = MethodChannel('rift/android/shell');
  const iosNotificationsChannel = MethodChannel('rift/ios/notifications');

  setUp(() {
    AndroidShell.debugIsAndroidOverride = true;
    IOSNotifications.debugIsIOSOverride = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, (call) async {
      switch (call.method) {
        case 'getNotificationPermissionStatus':
          return 'authorized';
        case 'getNotificationListenerAccessStatus':
          return 'authorized';
        case 'requestNotificationPermission':
          return true;
        case 'openNotificationListenerSettings':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    AndroidShell.debugIsAndroidOverride = null;
    IOSNotifications.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(iosNotificationsChannel, null);
  });

  Widget buildTestApp(FakeOnboardingClient client) {
    return MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const OnboardingScreen(),
      ),
    );
  }

  testWidgets(
      'OnboardingScreen auto-skips local network page when discovery already works',
      (WidgetTester tester) async {
    final client = FakeOnboardingClient(localNetworkGranted: true);

    await tester.pumpWidget(buildTestApp(client));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(client.startDiscoveryCallCount, 1);
    expect(find.widgetWithText(FilledButton, 'Allow Unrestricted'),
        findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Grant Permission'),
      findsNothing,
    );
  });

  testWidgets(
      'OnboardingScreen keeps local network page when discovery precheck fails',
      (WidgetTester tester) async {
    final client = FakeOnboardingClient(localNetworkGranted: false);

    await tester.pumpWidget(buildTestApp(client));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(client.startDiscoveryCallCount, 1);
    expect(
      find.widgetWithText(FilledButton, 'Grant Permission'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Enable Alerts & Sync'),
        findsNothing);
  });

  testWidgets('OnboardingScreen uses iOS notifications and background copy',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    IOSNotifications.debugIsIOSOverride = true;
    var permissionRequested = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(iosNotificationsChannel, (call) async {
      switch (call.method) {
        case 'getPermissionStatus':
          return 'denied';
        case 'requestPermission':
          permissionRequested = true;
          return true;
      }
      return null;
    });

    final client = FakeOnboardingClient(localNetworkGranted: true);

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(find.textContaining('pairing requests, transfers'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Enable Alerts'));
    await tester.pumpAndSettle();

    expect(permissionRequested, isTrue);
    expect(find.text('Background Connectivity'), findsOneWidget);
    expect(
        find.textContaining('iOS controls background runtime'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Review Background Behavior'),
      findsOneWidget,
    );
  });

  testWidgets(
      'OnboardingScreen keeps alerts page when notification access is missing',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, (call) async {
      switch (call.method) {
        case 'getNotificationPermissionStatus':
          return 'authorized';
        case 'getNotificationListenerAccessStatus':
          return 'denied';
        case 'requestNotificationPermission':
          return true;
        case 'openNotificationListenerSettings':
          return true;
      }
      return null;
    });

    final client = FakeOnboardingClient(localNetworkGranted: true);

    await tester.pumpWidget(buildTestApp(client));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.widgetWithText(FilledButton, 'Enable Alerts & Sync'),
        findsOneWidget);
    expect(find.textContaining('mirror Android notifications'), findsOneWidget);
  });
}
