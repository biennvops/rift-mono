import 'dart:async';

import 'package:rift/screens/device_detail_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/media_playback/playback_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class FakeDeviceDetailClient extends JsonRpcRiftClient {
  FakeDeviceDetailClient() : super(FakeTransport());

  final _trustChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerLostController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _deviceStatusController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  List<Map<String, dynamic>> trustedPeers = [
    {
      'deviceId': 'rift-phone',
      'displayName': 'Pixel 9',
      'platform': 'android',
      'trustState': 'trusted',
      'presence': 'online',
      'capabilities': ['presence.basic'],
    },
  ];
  bool revokeCalled = false;
  String? revokedDeviceId;

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onTrustChanged =>
      _trustChangedController.stream;

  @override
  Stream<Map<String, dynamic>> get onPeerLost => _peerLostController.stream;

  @override
  Stream<Map<String, dynamic>> get onDeviceStatusUpdated =>
      _deviceStatusController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  @override
  Stream<Map<String, dynamic>> get onPeerDiscovered => const Stream.empty();

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
  Future<dynamic> listTrustedPeers() async => {'peers': trustedPeers};

  @override
  Future<dynamic> revokeTrust(String deviceId, String reason) async {
    revokeCalled = true;
    revokedDeviceId = deviceId;
    return {'revoked': true};
  }

  Future<void> emitTrustChanged(Map<String, dynamic> event) async {
    _trustChangedController.add(event);
  }

  Future<void> emitPeerLost(Map<String, dynamic> event) async {
    _peerLostController.add(event);
  }

  Future<void> emitDeviceStatus(Map<String, dynamic> event) async {
    _deviceStatusController.add(event);
  }
}

void main() {
  Widget buildTestApp(
    FakeDeviceDetailClient client, {
    VoidCallback? onClose,
    bool isSelf = false,
    MediaPlaybackPresentation? mediaPlayback,
  }) {
    return MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: DeviceDetailScreen(
          peer: client.trustedPeers.first,
          isOnline: true,
          isSelf: isSelf,
          mediaPlayback: mediaPlayback,
          onClose: onClose,
        ),
      ),
    );
  }

  testWidgets('DeviceDetailScreen does not overflow at narrow desktop width',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-abcdefghijklmnopqrstuvwxyz234567',
          'displayName': 'Pixel 9 Pro Connected Device',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'lastSeenAt': '2026-07-29T00:00:00Z',
          'capabilities': ['presence.basic'],
        },
      ];

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Revoke Trust'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-view')), findsNothing);
    expect(find.textContaining('Block Device'), findsNothing);
    expect(
      find.text('ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567'),
      findsOneWidget,
    );
  });

  testWidgets(
      'DeviceDetailScreen shows removed state when trusted peer disappears',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(find.text('Pixel 9'), findsWidgets);
    expect(find.text('Online'), findsOneWidget);

    client.trustedPeers = const [];
    await client.emitTrustChanged({
      'deviceId': 'rift-phone',
      'previousState': 'trusted',
      'newState': 'revoked',
      'reason': 'removed.remote',
    });
    await tester.pumpAndSettle();

    expect(find.text('Pixel 9 is no longer available'), findsOneWidget);
    expect(find.text('Back to home'), findsOneWidget);
  });

  testWidgets(
      'DeviceDetailScreen marks peer offline when peer lost event arrives',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(find.text('Online'), findsOneWidget);

    await client.emitPeerLost({'deviceId': 'rift-phone'});
    await tester.pumpAndSettle();

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Device unavailable'), findsNothing);
  });

  testWidgets('DeviceDetailScreen renders and updates peer power status',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-phone',
          'displayName': 'Pixel 9',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['device.status', 'presence.basic'],
          'deviceStatus': {
            'sourceDeviceId': 'rift-phone',
            'batteryPercent': 64,
            'chargingState': 'charging',
            'powerSource': 'usb',
            'lowPowerMode': false,
            'observedAt': '2026-07-29T00:00:00Z',
          },
        },
      ];

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(find.text('Power status'), findsOneWidget);
    expect(find.text('64%'), findsOneWidget);
    expect(find.text('Charging'), findsOneWidget);
    expect(find.text('USB power'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.textContaining('Stale ·'), findsNothing);

    await tester.pump(const Duration(minutes: 30));
    expect(find.textContaining('Stale ·'), findsOneWidget);

    await client.emitDeviceStatus({
      'sourceDeviceId': 'rift-phone',
      'batteryPercent': 59,
      'chargingState': 'discharging',
      'powerSource': 'battery',
      'lowPowerMode': true,
      'observedAt': '2026-07-29T00:05:00Z',
    });
    await tester.pumpAndSettle();

    expect(find.text('59%'), findsOneWidget);
    expect(find.text('Discharging'), findsOneWidget);
    expect(find.text('Battery'), findsWidgets);
    expect(find.text('On'), findsOneWidget);
    expect(find.textContaining('Stale ·'), findsNothing);
  });

  testWidgets('DeviceDetailScreen marks power status stale on peer loss',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-phone',
          'displayName': 'Pixel 9',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'deviceStatus': {
            'sourceDeviceId': 'rift-phone',
            'batteryPresent': true,
            'batteryPercent': 64,
            'observedAt': '2026-07-29T00:00:00Z',
          },
        },
      ];

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stale ·'), findsNothing);

    await client.emitPeerLost({'deviceId': 'rift-phone'});
    await tester.pumpAndSettle();

    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('Stale ·'), findsOneWidget);
  });

  testWidgets('DeviceDetailScreen renders a peer without a battery',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-desktop',
          'displayName': 'Desktop',
          'platform': 'windows',
          'trustState': 'trusted',
          'presence': 'online',
          'deviceStatus': {
            'sourceDeviceId': 'rift-desktop',
            'batteryPresent': false,
            'powerSource': 'ac',
            'observedAt': '2026-07-29T00:00:00Z',
          },
        },
      ];

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(find.text('No battery'), findsOneWidget);
    expect(find.text('AC power'), findsOneWidget);
  });

  testWidgets('embedded trusted peer uses the desktop focus presentation',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-phone-1234',
          'displayName': 'Pixel 9',
          'platform': 'android',
          'osVersion': 'Android 16',
          'protocolVersion': '0.1-draft',
          'fingerprint': 'ABCD-EFGH-IJKL-MNOP',
          'pairedAt': '2026-07-28T12:00:00Z',
          'lastSeenAt': '2026-07-29T00:00:00Z',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': [
            'clipboard.offer_fetch',
            'device.status',
            'presence.basic',
          ],
          'deviceStatus': {
            'sourceDeviceId': 'rift-phone-1234',
            'batteryPercent': 64,
            'chargingState': 'charging',
            'powerSource': 'usb',
            'lowPowerMode': false,
            'observedAt': '2026-07-29T00:00:00Z',
          },
        },
      ];

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-core')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-focus-node-power')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-security')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-identity')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-capabilities')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-info')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-media')),
      findsNothing,
    );
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('Authorized Trusted Peer'), findsNothing);
    expect(find.text('Actions'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('device-focus-node-identity')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('device-focus-panel-identity')),
      findsOneWidget,
    );
    expect(find.text('rift-phone-1234'), findsOneWidget);
    expect(find.text('ABCD-EFGH-IJKL-MNOP'), findsOneWidget);
    expect(find.text('Android 16'), findsOneWidget);
    expect(find.text('0.1-draft'), findsOneWidget);
  });

  testWidgets('desktop focus nodes support keyboard activation',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('device-focus-panel-security')),
      findsNothing,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('device-focus-panel-security')),
      findsOneWidget,
    );
  });

  testWidgets('desktop focus animates panel opening and closing',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();

    final identityNode =
        find.byKey(const ValueKey('device-focus-node-identity'));
    final identityPanel =
        find.byKey(const ValueKey('device-focus-panel-identity'));

    await tester.tap(identityNode);
    await tester.pump();

    expect(identityPanel, findsOneWidget);
    var panelFades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: identityPanel,
        matching: find.byType(FadeTransition),
      ),
    );
    expect(
      panelFades.map((fade) => fade.opacity.value),
      contains(lessThan(1)),
    );

    await tester.pump(const Duration(milliseconds: 120));
    panelFades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: identityPanel,
        matching: find.byType(FadeTransition),
      ),
    );
    expect(
      panelFades.map((fade) => fade.opacity.value),
      contains(inExclusiveRange(0, 1)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('device-focus-panel-close')),
    );
    await tester.pump();

    expect(identityPanel, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    panelFades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: identityPanel,
        matching: find.byType(FadeTransition),
      ),
    );
    expect(
      panelFades.map((fade) => fade.opacity.value),
      contains(inExclusiveRange(0, 1)),
    );

    await tester.pumpAndSettle();
    expect(identityPanel, findsNothing);
  });

  testWidgets('desktop focus power panel follows live status updates',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-phone',
          'displayName': 'Pixel 9',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['device.status', 'presence.basic'],
          'deviceStatus': {
            'sourceDeviceId': 'rift-phone',
            'batteryPercent': 64,
            'chargingState': 'charging',
            'powerSource': 'usb',
            'lowPowerMode': false,
            'observedAt': '2026-07-29T00:00:00Z',
          },
        },
      ];

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-focus-node-power')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('device-focus-panel-power')),
      findsOneWidget,
    );
    expect(find.text('64%'), findsWidgets);
    expect(find.text('Charging'), findsOneWidget);
    expect(find.text('USB power'), findsOneWidget);

    await client.emitDeviceStatus({
      'sourceDeviceId': 'rift-phone',
      'batteryPercent': 59,
      'chargingState': 'discharging',
      'powerSource': 'battery',
      'lowPowerMode': true,
      'observedAt': '2026-07-29T00:05:00Z',
    });
    await tester.pumpAndSettle();

    expect(find.text('64%'), findsNothing);
    expect(find.text('59%'), findsWidgets);
    expect(find.text('Discharging'), findsOneWidget);
    expect(find.text('Battery'), findsWidgets);
    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('desktop focus stays mounted and marks status stale on peer loss',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-phone',
          'displayName': 'Pixel 9',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'deviceStatus': {
            'sourceDeviceId': 'rift-phone',
            'batteryPercent': 64,
            'observedAt': '2026-07-29T00:00:00Z',
          },
        },
      ];

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-focus-node-power')));
    await tester.pumpAndSettle();

    await client.emitPeerLost({'deviceId': 'rift-phone'});
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
    expect(find.text('Offline'), findsWidgets);
    expect(find.textContaining('Stale ·'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop focus preserves removed peer state',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);

    await client.emitTrustChanged({
      'deviceId': 'rift-phone',
      'previousState': 'trusted',
      'newState': 'revoked',
      'reason': 'removed.remote',
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-view')), findsNothing);
    expect(find.text('Pixel 9 is no longer available'), findsOneWidget);
    expect(find.text('Back to home'), findsOneWidget);
  });

  testWidgets('desktop focus revocation remains confirmation gated',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var onCloseCalled = false;
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(
      buildTestApp(
        client,
        onClose: () {
          onCloseCalled = true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('device-focus-node-security')));
    await tester.pumpAndSettle();
    expect(client.revokeCalled, isFalse);

    final revokeButton =
        find.byKey(const ValueKey('device-focus-revoke-trust'));
    await tester.ensureVisible(revokeButton);
    await tester.pumpAndSettle();
    await tester.tap(revokeButton);
    await tester.pumpAndSettle();
    expect(find.text('Revoke Trust?'), findsOneWidget);
    expect(client.revokeCalled, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Revoke Trust'));
    await tester.pumpAndSettle();

    expect(client.revokeCalled, isTrue);
    expect(client.revokedDeviceId, 'rift-phone');
    expect(onCloseCalled, isTrue);
  });

  testWidgets('desktop focus exposes capability-gated action nodes',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-actions',
          'displayName': 'Action Peer',
          'platform': 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': [
            'clipboard.offer_fetch',
            'file.transfer',
            'presence.basic',
          ],
        },
      ];
    var clipboardCount = 0;
    var sendCount = 0;
    var transfersCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: DeviceDetailScreen(
            peer: client.trustedPeers.first,
            isOnline: true,
            onClose: () {},
            onOpenClipboardActivity: () => clipboardCount++,
            onSendFile: () => sendCount++,
            onViewTransferActivity: () => transfersCount++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-node-clipboard')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('device-focus-node-files')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('device-focus-node-clipboard')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-focus-open-clipboard')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('device-focus-node-files')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('device-focus-send-file')),
    );
    await tester.tap(find.byKey(const ValueKey('device-focus-send-file')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('device-focus-view-transfers')),
    );
    await tester.tap(find.byKey(const ValueKey('device-focus-view-transfers')));

    expect(clipboardCount, 1);
    expect(sendCount, 1);
    expect(transfersCount, 1);
  });

  testWidgets('desktop focus hides unsupported action nodes',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-no-actions',
          'displayName': 'Basic Peer',
          'platform': 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['presence.basic'],
        },
      ];

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-node-clipboard')),
        findsNothing);
    expect(find.byKey(const ValueKey('device-focus-node-files')), findsNothing);
    expect(find.byKey(const ValueKey('device-focus-node-capabilities')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-node-media')), findsNothing);
  });

  testWidgets('desktop focus exposes stable Media states when supported',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-media',
          'displayName': 'Media Peer',
          'platform': 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'lastSeenAt': '2026-08-01T09:00:00Z',
          'capabilities': ['media.playback', 'presence.basic'],
        },
      ];
    final playing = MediaPlaybackPresentation.fromRecord({
      'playbackId': 'session-1',
      'sourceDeviceId': 'rift-media',
      'appName': 'Rift Music',
      'title': 'Northern Lights',
      'artist': 'Signal Bloom',
      'album': 'Continuity',
      'playbackState': 'playing',
      'positionMs': 31000,
      'durationMs': 181000,
      'updatedAt': '2026-08-01T10:00:00Z',
    });

    await tester.pumpWidget(
      buildTestApp(client, onClose: () {}, mediaPlayback: playing),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-node-info')), findsNothing);
    expect(
      find.byKey(const ValueKey('device-focus-node-media')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-media-playing')),
      findsOneWidget,
    );
    expect(find.text('Northern Lights'), findsOneWidget);
    expect(find.text('Playing'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('device-focus-node-media')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('device-focus-panel-media')),
      findsOneWidget,
    );
    expect(find.text('Signal Bloom'), findsOneWidget);
    expect(find.text('Continuity'), findsOneWidget);
    expect(find.text('Rift Music'), findsOneWidget);
    expect(find.text('0:31 / 3:01'), findsOneWidget);

    final paused = MediaPlaybackPresentation.fromRecord({
      'playbackId': 'session-1',
      'sourceDeviceId': 'rift-media',
      'appName': 'Rift Music',
      'title': 'Northern Lights',
      'playbackState': 'paused',
      'updatedAt': '2026-08-01T10:01:00Z',
    });
    await tester.pumpWidget(
      buildTestApp(client, onClose: () {}, mediaPlayback: paused),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('device-focus-media-paused')),
      findsOneWidget,
    );
    expect(find.text('Paused'), findsWidgets);

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();
    expect(find.text('Nothing playing'), findsWidgets);
    expect(
        find.byKey(const ValueKey('device-focus-node-media')), findsOneWidget);
  });

  testWidgets('desktop focus respects reduced motion accessibility settings',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-reduced-motion',
          'displayName': 'Quiet Peer',
          'platform': 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['clipboard.offer_fetch', 'presence.basic'],
        },
      ];
    var clipboardCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Provider<JsonRpcRiftClient>.value(
            value: client,
            child: DeviceDetailScreen(
              peer: client.trustedPeers.first,
              isOnline: true,
              onClose: () {},
              onOpenClipboardActivity: () => clipboardCount++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-node-clipboard')),
        findsOneWidget);

    await client.emitPeerLost({'deviceId': 'rift-reduced-motion'});
    await tester.pumpAndSettle();
    expect(find.text('Offline'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('device-focus-node-clipboard')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('device-focus-open-clipboard')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-focus-open-clipboard')));
    expect(clipboardCount, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop focus remains overflow free at target pane sizes',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = FakeDeviceDetailClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-abcdefghijklmnopqrstuvwxyz234567',
          'displayName':
              'A very long trusted desktop device name for layout coverage',
          'platform': 'linux',
          'fingerprint': 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ12-3456',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': [
            'clipboard.offer_fetch',
            'device.status',
            'file.transfer',
            'presence.basic',
          ],
          'deviceStatus': {
            'sourceDeviceId': 'rift-abcdefghijklmnopqrstuvwxyz234567',
            'batteryPercent': 42,
            'chargingState': 'discharging',
            'observedAt': '2026-07-29T00:00:00Z',
          },
        },
      ];

    for (final size in const [
      Size(1024, 768),
      Size(1440, 900),
      Size(520, 620),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(buildTestApp(client, onClose: () {}));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'viewport $size');
      expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-focus-core')), findsOneWidget);
    }
  });

  testWidgets(
      'DeviceDetailScreen renders self device details and copy actions when isSelf is true',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: DeviceDetailScreen(
            peer: <String, dynamic>{
              'deviceId': 'rift-local-device-12345678',
              'displayName': 'My Laptop',
              'platform': 'macos',
              'fingerprint': '1234-5678-90AB-CDEF',
            },
            isOnline: true,
            isSelf: true,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('My Laptop'), findsWidgets);
    expect(find.text('This Device'), findsWidgets);
    expect(find.text('Copy Device ID'), findsOneWidget);
    expect(find.text('Copy Fingerprint'), findsOneWidget);
    expect(find.text('Revoke Trust'), findsNothing);
    expect(find.byKey(const ValueKey('device-focus-view')), findsNothing);
  });
}
