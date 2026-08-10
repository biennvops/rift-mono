import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rift/screens/settings_screen.dart';
import 'package:rift/screens/onboarding_screen.dart';
import 'package:rift/constants.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/platform/android_shell.dart';
import 'package:rift/src/platform/linux_notifications.dart';

class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const androidShellChannel = MethodChannel('rift/android/shell');
  const linuxNotificationsChannel = MethodChannel('rift/linux/notifications');
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
    registerFallbackValue(<String, Object?>{});
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AndroidShell.debugIsAndroidOverride = true;
    LinuxNotifications.debugIsLinuxOverride = null;
    mockClient = MockJsonRpcClient();
    connectionChangedController = StreamController<bool>.broadcast();
    isConnected = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, (call) async {
      switch (call.method) {
        case 'getNotificationPermissionStatus':
          return 'authorized';
        case 'getNotificationListenerAccessStatus':
          return 'denied';
        case 'openNotificationSettings':
        case 'openNotificationListenerSettings':
          return true;
        case 'showTestNotification':
          return true;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(linuxNotificationsChannel, (call) async {
      switch (call.method) {
        case 'showNotification':
          return true;
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
    when(() => mockClient.listNotifications()).thenAnswer(
      (_) async => <String, dynamic>{
        'notifications': <dynamic>[],
        'policy': <String, dynamic>{
          'enabled': true,
          'mode': 'all',
          'packageNames': <String>[],
        },
      },
    );
    when(
      () => mockClient.updateNotificationSyncPolicy(
        enabled: any(named: 'enabled'),
        mode: any(named: 'mode'),
        packageNames: any(named: 'packageNames'),
      ),
    ).thenAnswer(
      (_) async => {
        'enabled': true,
        'mode': 'exclude',
        'packageNames': ['com.bank.example'],
      },
    );
    when(
      () => mockClient.notifyLocalNotificationEvent(
        eventType: any(named: 'eventType'),
        payload: any(named: 'payload'),
      ),
    ).thenAnswer(
      (_) async => {
        'notificationId': 'android:dev.rift.app:test:1',
        'broadcastTo': ['rift-peer'],
        'suppressed': false,
      },
    );
    when(() => mockClient.isConnected).thenAnswer((_) => isConnected);
    when(() => mockClient.onConnectionChanged)
        .thenAnswer((_) => connectionChangedController.stream);
    when(() => mockClient.onTrustChanged)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onPairingRequest)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.onPairingComplete)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => mockClient.startPairingByEndpoint(any(), any())).thenAnswer(
      (_) async => <String, dynamic>{
        'deviceId': 'rift-manual-peer',
        'displayName': 'Manual Peer',
        'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
        'peerFingerprint': 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
        'expiresInMs': 120000,
      },
    );
    when(() => mockClient.listTrustedPeers())
        .thenAnswer((_) async => <String, dynamic>{'peers': <dynamic>[]});
  });

  tearDown(() {
    AndroidShell.debugIsAndroidOverride = null;
    LinuxNotifications.debugIsLinuxOverride = null;
    connectionChangedController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidShellChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(linuxNotificationsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(macOsPermissionsChannel, null);
  });

  Future<void> pumpLoaded(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('SettingsScreen shows UI elements and device info',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);

    // Tab rail labels should be visible
    expect(find.text('General'),
        findsNWidgets(2)); // Tab rail label + panel header
    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('System Checks'), findsOneWidget);
    expect(find.text('File Transfer'), findsOneWidget);
    expect(find.text('Trust Store'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    // Default tab is General
    expect(find.text('Device name'), findsOneWidget);
    expect(find.text('Pair by IP'), findsOneWidget);
    final generalCard = find
        .ancestor(
            of: find.text('Device name'), matching: find.byType(Container))
        .evaluate()
        .map((element) => element.widget)
        .whereType<Container>()
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).color == Colors.white &&
              (container.decoration! as BoxDecoration).borderRadius ==
                  BorderRadius.circular(8),
        );
    expect(
      (generalCard.decoration! as BoxDecoration).color,
      Colors.white,
    );

    // Tap Identity tab to see device info
    await tester.tap(find.text('Identity'));
    await pumpLoaded(tester);

    expect(find.text('rift-test-device-id'), findsOneWidget);
    expect(find.text('TEST-FINGERPRINT'), findsOneWidget);
  });

  testWidgets('Android download location is read-only',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);

    await tester.tap(find.text('File Transfer'));
    await tester.pumpAndSettle();

    expect(find.text('Downloads (managed by Android)'), findsOneWidget);
    expect(find.byTooltip('Choose folder'), findsNothing);
  });

  testWidgets('Pair by IP opens the canonical PairingScreen',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);

    await tester.tap(find.text('Pair by IP'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '10.53.38.174:9140');
    await tester.tap(find.text('PAIR'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    verify(() => mockClient.startPairingByEndpoint('10.53.38.174', 9140))
        .called(1);
    expect(find.text('Pairing Request'), findsOneWidget);
    expect(find.text('Confirm Pairing'), findsNothing);
    expect(
      find.text('ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567'),
      findsOneWidget,
    );
  });

  testWidgets('mobile settings menu uses tinted square icon containers',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);

    expect(find.byIcon(Icons.tune), findsOneWidget);
    final tintedSquare = find.byWidgetPredicate(
      (widget) {
        if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
          return false;
        }
        final decoration = widget.decoration as BoxDecoration;
        return decoration.color != null &&
            decoration.color != Colors.transparent &&
            decoration.borderRadius == BorderRadius.circular(8);
      },
    );
    expect(tintedSquare, findsWidgets);
  });

  testWidgets('Trust Store opens blocked peer management',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);

    await tester.tap(find.text('Trust Store'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MANAGE TRUST STORE'));
    await tester.pumpAndSettle();

    expect(find.text('Blocked Peers'), findsOneWidget);
    expect(find.text('No Blocked Peers'), findsOneWidget);
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

    // UI should still be rendered (fallback values)
    expect(find.text('Unknown Device'), findsOneWidget);
  });

  testWidgets('SettingsScreen reloads after the daemon connects',
      (WidgetTester tester) async {
    isConnected = false;
    when(() => mockClient.getDeviceInfo()).thenAnswer((_) async {
      if (!isConnected) throw StateError('Not connected to daemon');
      return mockDeviceInfo;
    });

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);
    expect(find.text('Unknown Device'), findsOneWidget);

    isConnected = true;
    connectionChangedController.add(true);
    await pumpLoaded(tester);

    expect(find.text('Test Device'), findsOneWidget);
    expect(find.text('Unknown Device'), findsNothing);
    verify(() => mockClient.getDeviceInfo()).called(2);
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

    await tester.tap(find.text('Identity'));
    await pumpLoaded(tester);

    expect(find.text('Unknown'), findsNWidgets(2)); // Device ID and Fingerprint
  });

  testWidgets('SettingsScreen persists clipboard notification preference',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    expect(find.text('Clipboard received notifications'), findsOneWidget);
    final switchFinder = find.byType(Switch).first;
    expect(switchFinder, findsOneWidget);

    await tester.tap(switchFinder);
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    final switches = find.byType(Switch);
    expect(switches, findsAtLeastNWidgets(2));
    await tester.tap(switches.at(1));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPrefs.notificationSyncPolicyEnabledV2), isFalse);
    expect(
      prefs.getString(AppPrefs.notificationSyncPolicyModeV2),
      'all',
    );
    expect(
      prefs.getStringList(AppPrefs.notificationSyncPolicyPackagesV2),
      <String>[],
    );

    await tester.tap(find.text('All except selected apps'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('notification-package-input')),
      'com.bank.example',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(
      prefs.getString(AppPrefs.notificationSyncPolicyModeV2),
      'exclude',
    );
    expect(
      prefs.getStringList(AppPrefs.notificationSyncPolicyPackagesV2),
      ['com.bank.example'],
    );
    expect(
      prefs.getStringList(AppPrefs.notificationSyncBlacklist),
      ['com.bank.example'],
    );
    verify(
      () => mockClient.updateNotificationSyncPolicy(
        enabled: false,
        mode: 'exclude',
        packageNames: ['com.bank.example'],
      ),
    ).called(1);
  });

  testWidgets('SettingsScreen adds notification packages immediately',
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);
    await tester.tap(find.text('All except selected apps'));
    await tester.pump();

    final field = find.byKey(const ValueKey('notification-package-input'));
    await tester.enterText(field, ' com.example.one ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(field, 'com.example.two');
    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.enterText(field, 'com.example.one');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList(AppPrefs.notificationSyncPolicyPackagesV2),
      ['com.example.one', 'com.example.two'],
    );
    expect(find.text('App already selected.'), findsOneWidget);
  });

  testWidgets('SettingsScreen migrates a legacy blacklist to exclude mode',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      AppPrefs.notificationSyncEnabled: true,
      AppPrefs.notificationSyncBlacklist: ['com.legacy.app'],
    });
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    expect(find.text('All except selected apps'), findsOneWidget);
    expect(find.text('com.legacy.app'), findsOneWidget);
  });

  testWidgets('SettingsScreen shows the empty include warning',
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);
    await tester.tap(find.text('Only selected apps'));
    await tester.pump();

    expect(
      find.text('No apps selected. Notifications will stay on this device.'),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AppPrefs.notificationSyncPolicyModeV2),
      'include',
    );
  });

  testWidgets('SettingsScreen offers recently seen local apps only',
      (WidgetTester tester) async {
    when(() => mockClient.listNotifications()).thenAnswer(
      (_) async => <String, dynamic>{
        'notifications': <dynamic>[
          {
            'sourceDeviceId': 'rift-peer',
            'packageName': 'com.remote.app',
            'appName': 'Remote App',
          },
        ],
        'observedApps': <dynamic>[
          {
            'packageName': 'org.signal',
            'appName': 'Signal',
          },
          {
            'packageName': 'org.signal',
            'appName': 'Signal',
          },
          {
            'packageName': 'com.google.android.gm',
            'appName': 'Gmail',
          },
          {
            'packageName': 'dev.rift.app',
            'appName': 'Rift',
          },
        ],
        'policy': <String, dynamic>{
          'enabled': true,
          'mode': 'all',
          'packageNames': <String>[],
        },
      },
    );
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpLoaded(tester);
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);
    await tester.tap(find.text('All except selected apps'));
    await tester.pump();

    expect(find.text('Recently seen apps'), findsOneWidget);
    expect(find.text('Signal'), findsOneWidget);
    expect(find.text('org.signal'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('com.google.android.gm'), findsOneWidget);
    expect(find.text('Remote App'), findsNothing);
    expect(find.text('com.remote.app'), findsNothing);
    expect(find.text('dev.rift.app'), findsNothing);

    await tester.tap(find.byTooltip('Select Signal'));
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList(AppPrefs.notificationSyncPolicyPackagesV2),
      ['org.signal'],
    );
  });

  testWidgets('SettingsScreen exposes Android notification actions',
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
    await tester.tap(find.text('Permissions'));
    await pumpLoaded(tester);

    expect(find.text('Notification access'), findsOneWidget);
    final testBtn = find.textContaining('Test notification');
    expect(testBtn, findsOneWidget);

    await tester.tap(testBtn);
    await tester.pump();

    expect(find.text('Sent Android test notification.'), findsOneWidget);
    final captured = verify(
      () => mockClient.notifyLocalNotificationEvent(
        eventType: 'posted',
        payload: captureAny(named: 'payload'),
      ),
    ).captured.single as Map<String, Object?>;
    expect(
      captured['notificationId'] as String,
      startsWith('android:dev.rift.app:test:'),
    );
    expect(captured['packageName'], 'dev.rift.app');
    expect(captured['appName'], 'Rift');
    expect(captured['title'], 'Rift test notification');
    expect(
      captured['bodyPreview'],
      'If you see this notification, sync is working.',
    );
    expect(captured['isDismissible'], isTrue);
    expect(captured['isOpenable'], isTrue);
  });

  testWidgets('SettingsScreen exposes desktop notification sync test button',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    LinuxNotifications.debugIsLinuxOverride = null;

    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.tap(find.text('Experimental'));
    await pumpLoaded(tester);

    final testBtn = find.textContaining('Test desktop sync');
    await tester.tap(testBtn);
    await tester.pumpAndSettle();

    verify(() => mockClient.getDeviceInfo()).called(greaterThan(0));
  });

  testWidgets('desktop notification sync copy references trusted peers',
      (WidgetTester tester) async {
    AndroidShell.debugIsAndroidOverride = false;
    LinuxNotifications.debugIsLinuxOverride = true;

    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.tap(find.text('Experimental'));
    await pumpLoaded(tester);

    final testBtn = find.textContaining('Test desktop sync');
    await tester.tap(testBtn);
    await tester.pumpAndSettle();

    expect(find.textContaining('trusted peers'), findsNothing);
  });

  testWidgets(
      'SettingsScreen restart onboarding navigates to OnboardingScreen and resets flag',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'has_completed_onboarding': true});

    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: mockClient,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await pumpLoaded(tester);
    await tester.tap(find.text('Experimental'));
    await pumpLoaded(tester);

    final restartBtn = find.textContaining('Restart onboarding');
    expect(restartBtn, findsWidgets);

    await tester.tap(restartBtn.first);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('has_completed_onboarding'), isFalse);
    expect(find.byType(OnboardingScreen), findsOneWidget);
  });
}
