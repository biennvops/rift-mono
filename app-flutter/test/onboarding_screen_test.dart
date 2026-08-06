import 'dart:async';

import 'package:rift/screens/onboarding_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/platform/android_shell.dart';
import 'package:rift/src/platform/macos_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_utils/fake_transport.dart';

class FakeOnboardingClient extends JsonRpcRiftClient {
  FakeOnboardingClient({this.localNetworkGranted = true})
      : super(FakeTransport());

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
    if (!localNetworkGranted) throw Exception('local network denied');
    return {'started': true};
  }
}

void main() {
  const androidShellChannel = MethodChannel('rift/android/shell');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AndroidShell.debugIsAndroidOverride = true;
    MacOSNotifications.debugIsMacOSOverride = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, (call) async {
      switch (call.method) {
        case 'getNotificationPermissionStatus':
        case 'getNotificationListenerAccessStatus':
          return 'authorized';
        case 'requestNotificationPermission':
        case 'openNotificationListenerSettings':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    AndroidShell.debugIsAndroidOverride = null;
    MacOSNotifications.debugIsMacOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, null);
  });

  Widget buildTestApp(FakeOnboardingClient client) {
    return MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const OnboardingScreen(),
      ),
    );
  }

  Future<void> openAboutPage(
    WidgetTester tester,
    FakeOnboardingClient client,
  ) async {
    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
  }

  Future<void> declinePermissionPrompts(
    WidgetTester tester, {
    int count = 3,
  }) async {
    for (var index = 0; index < count; index++) {
      expect(find.text('Not now'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('welcome animates before enabling Get started',
      (WidgetTester tester) async {
    final client = FakeOnboardingClient();
    await tester.pumpWidget(buildTestApp(client));

    expect(find.text('Rift'), findsOneWidget);
    expect(find.text('Your devices, working together.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Get started'),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Get started'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('project page explains local operation without Internet',
      (WidgetTester tester) async {
    final client = FakeOnboardingClient();
    await openAboutPage(tester, client);

    expect(find.text('Continuity without the cloud'), findsOneWidget);
    expect(find.textContaining('No account, cloud server'), findsOneWidget);
    expect(find.textContaining('Internet is optional'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
  });

  testWidgets('permissions stay optional when access is missing',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, (call) async {
      switch (call.method) {
        case 'getNotificationPermissionStatus':
        case 'getNotificationListenerAccessStatus':
          return 'denied';
        case 'requestNotificationPermission':
        case 'openNotificationListenerSettings':
          return true;
      }
      return null;
    });
    final client = FakeOnboardingClient(localNetworkGranted: false);
    await openAboutPage(tester, client);
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Allow local network?'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Open Rift'),
          )
          .onPressed,
      isNull,
    );
    await declinePermissionPrompts(tester);

    expect(find.text('Enable the features you want'), findsOneWidget);
    expect(find.text('Local network'), findsOneWidget);
    expect(find.text('Notification sync'), findsOneWidget);
    expect(find.text('Internet'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Open Rift'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('onboarding remains overflow-free on a small phone',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = FakeOnboardingClient(localNetworkGranted: false);
    await openAboutPage(tester, client);
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await declinePermissionPrompts(tester);

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Open Rift'));
    expect(find.text('Open Rift'), findsOneWidget);
  });

  testWidgets('desktop also requires a choice for every relevant permission',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    final client = FakeOnboardingClient(localNetworkGranted: false);
    await openAboutPage(tester, client);
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Allow local network?'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Open Rift'),
          )
          .onPressed,
      isNull,
    );

    await declinePermissionPrompts(tester, count: 2);

    expect(find.text('Notification sync'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Open Rift'),
          )
          .onPressed,
      isNotNull,
    );
  });
}
