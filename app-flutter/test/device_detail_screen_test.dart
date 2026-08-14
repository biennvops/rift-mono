import 'dart:async';
import 'dart:convert';

import 'package:rift/screens/device_detail_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/media_playback/playback_presentation.dart';
import 'package:rift/widgets/media_playback_activity_ring.dart';
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
        find.byKey(const ValueKey('device-focus-device-id')), findsOneWidget);
    expect(find.text('rift-phone-1234'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-focus-node-power')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-security')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-features')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-identity')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-capabilities')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-clipboard')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-files')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-media')),
      findsNothing,
    );
    expect(find.text('Pixel 9'), findsWidgets);
    expect(find.textContaining('Android 16'), findsOneWidget);
    expect(find.textContaining('Rift 0.1-draft'), findsOneWidget);
    expect(find.text('Authorized Trusted Peer'), findsNothing);
    expect(find.text('Actions'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('device-focus-node-security')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('device-focus-panel-security')),
      findsOneWidget,
    );
    expect(find.text('ABCD-EFGH-IJKL-MNOP'), findsOneWidget);
  });

  testWidgets('desktop focus nodes support keyboard activation',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();

    final securityNode =
        find.byKey(const ValueKey('device-focus-node-security'));
    final securityInkWell = tester.widget<InkWell>(
      find.descendant(of: securityNode, matching: find.byType(InkWell)),
    );
    securityInkWell.focusNode!.requestFocus();
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

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('device-focus-panel-security')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
  });

  testWidgets('desktop focus transforms a node into a centered panel',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();

    final securityNode =
        find.byKey(const ValueKey('device-focus-node-security'));
    final securityPanel =
        find.byKey(const ValueKey('device-focus-panel-security'));
    final sourceRect = tester.getRect(securityNode);

    await tester.tap(securityNode);
    await tester.pump();

    expect(securityPanel, findsOneWidget);
    final openingRect = tester.getRect(securityPanel);
    expect((openingRect.center - sourceRect.center).distance, lessThan(0.1));
    expect((openingRect.width - sourceRect.width).abs(), lessThan(0.1));
    expect((openingRect.height - sourceRect.height).abs(), lessThan(0.1));

    await tester.pump(const Duration(milliseconds: 120));
    final midpointRect = tester.getRect(securityPanel);
    expect(midpointRect.center, isNot(openingRect.center));
    expect(midpointRect.width, greaterThan(openingRect.width));

    await tester.pumpAndSettle();
    final settledRect = tester.getRect(securityPanel);
    final sceneRect = tester.getRect(
      find.byKey(const ValueKey('device-focus-panel-scrim')),
    );
    expect((settledRect.center - sceneRect.center).distance, lessThan(0.1));
    expect(settledRect.width, inInclusiveRange(440, 540));
    expect(settledRect.bottom, lessThan(sceneRect.bottom));

    await tester.tap(
      find.byKey(const ValueKey('device-focus-panel-close')),
    );
    await tester.pump();
    expect(securityPanel, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getRect(securityPanel).width, lessThan(settledRect.width));

    await tester.pumpAndSettle();
    expect(securityPanel, findsNothing);
    final securityInkWell = tester.widget<InkWell>(
      find.descendant(of: securityNode, matching: find.byType(InkWell)),
    );
    expect(securityInkWell.focusNode!.hasFocus, isTrue);
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

    expect(find.byKey(const ValueKey('device-focus-node-features')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-node-clipboard')),
        findsNothing);
    expect(find.byKey(const ValueKey('device-focus-node-files')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('device-focus-node-features')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('device-focus-panel-features')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('device-focus-feature-clipboard.offer_fetch'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-feature-file.transfer')),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('device-focus-open-clipboard')),
    );
    await tester.tap(find.byKey(const ValueKey('device-focus-open-clipboard')));
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
        findsNothing);
    expect(find.byKey(const ValueKey('device-focus-node-features')),
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
    final playing = MediaPlaybackPresentation.fromRecord(
      {
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
      },
      artworkBytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      artworkIdentity: 'artwork-one',
      accentColor: const Color(0xFFD62828),
    );

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
    expect(
      find.byKey(const ValueKey('device-focus-media-accented')),
      findsOneWidget,
    );
    expect(find.byType(MediaPlaybackActivityRing), findsOneWidget);
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
    expect(
      find.byKey(const ValueKey('device-focus-media-artwork-artwork-one')),
      findsOneWidget,
    );

    final paused = MediaPlaybackPresentation.fromRecord(
      {
        'playbackId': 'session-1',
        'sourceDeviceId': 'rift-media',
        'appName': 'Rift Music',
        'title': 'Northern Lights',
        'playbackState': 'paused',
        'updatedAt': '2026-08-01T10:01:00Z',
      },
      artworkBytes: playing.artworkBytes,
      artworkIdentity: playing.artworkIdentity,
      accentColor: playing.accentColor,
    );
    await tester.pumpWidget(
      buildTestApp(client, onClose: () {}, mediaPlayback: paused),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('device-focus-media-paused')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-media-accented')),
      findsOneWidget,
    );
    expect(find.byType(MediaPlaybackActivityRing), findsNothing);
    expect(find.text('Paused'), findsWidgets);

    await tester.pumpWidget(buildTestApp(client, onClose: () {}));
    await tester.pumpAndSettle();
    expect(find.text('Nothing playing'), findsWidgets);
    expect(
      find.byKey(const ValueKey('device-focus-media-accented')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('device-focus-media-artwork-artwork-one')),
      findsNothing,
    );
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
    expect(find.byKey(const ValueKey('device-focus-node-features')),
        findsOneWidget);

    await client.emitPeerLost({'deviceId': 'rift-reduced-motion'});
    await tester.pumpAndSettle();
    expect(find.text('Offline'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('device-focus-node-features')),
    );
    await tester.pumpAndSettle();
    final reducedPanel =
        find.byKey(const ValueKey('device-focus-panel-features'));
    expect(reducedPanel, findsOneWidget);
    expect(
      (tester.getCenter(reducedPanel) -
              tester.getCenter(
                find.byKey(const ValueKey('device-focus-panel-scrim')),
              ))
          .distance,
      lessThan(0.1),
    );
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

  testWidgets('embedded self device uses local focus nodes',
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
    expect(find.text('This Device'), findsOneWidget);
    expect(find.text('rift-local-device-12345678'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-focus-node-media')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-features')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-focus-node-security')),
      findsNothing,
    );
    expect(find.text('Revoke Trust'), findsNothing);
  });
}
