import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rift/screens/device_detail_screen.dart';
import 'package:rift/screens/trusted_devices_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/widgets/device_hub/device_orbit_peer.dart';
import 'package:rift/widgets/media_playback_activity_ring.dart';
import 'test_utils/fake_transport.dart';

Future<Map<String, Object?>> _solidArtwork(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  final bytes = data!.buffer.asUint8List();
  return {
    'mediaType': 'image/png',
    'dataBase64': base64Encode(bytes),
    'byteSize': bytes.length,
  };
}

class FakeJsonRpcRiftClient extends JsonRpcRiftClient {
  FakeJsonRpcRiftClient() : super(FakeTransport());
  final _pairingCompleteController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerDiscoveredController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerLostController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _trustChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _mediaPostedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _mediaUpdatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _mediaRemovedController =
      StreamController<Map<String, dynamic>>.broadcast();
  bool unblockCalled = false;
  bool revokeCalled = false;
  bool resetRevokedCalled = false;
  bool rejectCalled = false;
  int startDiscoveryCallCount = 0;
  int stopDiscoveryCallCount = 0;
  String? manualPairAddress;
  int? manualPairPort;
  String? startedPairingDeviceId;
  int listTrustedPeersCallCount = 0;
  bool isDiscovering = true;
  List<Map<String, dynamic>> trustedPeers = [
    {
      'deviceId': 'rift-trusted',
      'displayName': 'Windows Laptop',
      'platform': 'windows',
      'trustState': 'trusted',
      'presence': 'online',
      'capabilities': ['presence.basic'],
    }
  ];
  List<Map<String, dynamic>> discoveredPeers = [
    {
      'deviceId': 'rift-discovered',
      'address': '192.168.1.10',
      'port': 11112,
      'trustState': 'discovered',
    }
  ];
  List<Map<String, dynamic>> mediaPlaybacks = [];
  Map<String, dynamic> deviceInfo = {
    'deviceId': 'rift-local-device',
    'displayName': 'Local Device',
    'platform': 'linux',
  };

  @override
  bool get isConnected => true;
  @override
  Stream<Map<String, dynamic>> get onPeerDiscovered =>
      _peerDiscoveredController.stream;
  @override
  Stream<Map<String, dynamic>> get onPeerLost => _peerLostController.stream;
  @override
  Stream<Map<String, dynamic>> get onTrustChanged =>
      _trustChangedController.stream;
  @override
  Stream<Map<String, dynamic>> get onPairingComplete =>
      _pairingCompleteController.stream;
  @override
  Stream<Map<String, dynamic>> get onMediaPlaybackPosted =>
      _mediaPostedController.stream;
  @override
  Stream<Map<String, dynamic>> get onMediaPlaybackUpdated =>
      _mediaUpdatedController.stream;
  @override
  Stream<Map<String, dynamic>> get onMediaPlaybackRemoved =>
      _mediaRemovedController.stream;

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
  Future<dynamic> getDeviceInfo() async => deviceInfo;
  @override
  Future<dynamic> listDiscoveredPeers() async => {
        'peers': discoveredPeers,
        'isDiscovering': isDiscovering,
      };
  @override
  Future<dynamic> listMediaPlayback() async => {'playbacks': mediaPlaybacks};
  @override
  Future<dynamic> listTrustedPeers() async {
    listTrustedPeersCallCount += 1;
    return {'peers': trustedPeers};
  }

  @override
  Future<dynamic> startDiscovery() async {
    startDiscoveryCallCount += 1;
    isDiscovering = true;
    return {'started': true};
  }

  @override
  Future<dynamic> stopDiscovery() async {
    stopDiscoveryCallCount += 1;
    isDiscovering = false;
    return {'stopped': true};
  }

  @override
  Future<dynamic> unblockPeer(String deviceId) async {
    unblockCalled = true;
    return {'unblocked': true};
  }

  @override
  Future<dynamic> resetRevokedPeer(String deviceId) async {
    resetRevokedCalled = true;
    return {'reset': true};
  }

  @override
  Future<dynamic> revokeTrust(String deviceId, String reason) async {
    revokeCalled = true;
    return {'revoked': true};
  }

  @override
  Future<dynamic> rejectPairing(String deviceId) async {
    rejectCalled = true;
    return {'rejected': true};
  }

  @override
  Future<dynamic> startPairing(String deviceId) async {
    startedPairingDeviceId = deviceId;
    return {
      'deviceId': deviceId,
      'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'peerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    };
  }

  @override
  Future<dynamic> startPairingByEndpoint(String address, int port) async {
    manualPairAddress = address;
    manualPairPort = port;
    return {
      'deviceId': 'rift-manual-peer',
      'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'peerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    };
  }

  Future<void> emitTrustChanged(Map<String, dynamic> event) async {
    _trustChangedController.add(event);
  }

  Future<void> emitPairingComplete(Map<String, dynamic> event) async {
    _pairingCompleteController.add(event);
  }

  Future<void> emitMediaPosted(Map<String, dynamic> event) async {
    _mediaPostedController.add(event);
  }

  Future<void> emitMediaUpdated(Map<String, dynamic> event) async {
    _mediaUpdatedController.add(event);
  }

  Future<void> emitMediaRemoved(Map<String, dynamic> event) async {
    _mediaRemovedController.add(event);
  }
}

void main() {
  testWidgets('TrustedDevicesScreen shows title', (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const TrustedDevicesScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Windows Laptop'), findsOneWidget);
    expect(find.text('Local Device'), findsOneWidget);
    expect(find.text('This Device'), findsOneWidget);
    expect(find.text('Devices Hub'), findsOneWidget);
  });

  testWidgets('trusted peer uses discovery name when trust record has none',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-peer-without-name',
          'trustState': 'trusted',
          'presence': 'online',
        },
      ]
      ..discoveredPeers = [
        {
          'deviceId': 'rift-peer-without-name',
          'displayName': 'Android Phone 73',
          'platform': 'android',
          'address': '192.168.1.32',
          'port': 11112,
        },
      ];

    await tester.pumpWidget(MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const TrustedDevicesScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Android Phone 73'), findsOneWidget);
    expect(find.text('rift-peer-witho'), findsNothing);
  });

  testWidgets('local device card opens compact identity details',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 600));
    final client = FakeJsonRpcRiftClient()
      ..deviceInfo = {
        'deviceId': 'rift-abcdefghijklmnopqrstuvwxyz234567',
        'displayName': 'Linux Desktop 111',
        'platform': 'linux',
        'fingerprint': 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ12-3456',
      };

    await tester.pumpWidget(MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const TrustedDevicesScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-device-card')));
    await tester.pumpAndSettle();

    expect(find.text('Device details'), findsOneWidget);
    expect(find.text('Linux Desktop 111'), findsWidgets);
    expect(find.text('rift-abcdefghijklmnopqrstuvwxyz234567'), findsOneWidget);
    expect(
      find.text('ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ12-3456'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TrustedDevicesScreen handles dense peer lists at target sizes',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final client = FakeJsonRpcRiftClient()
      ..trustedPeers = List<Map<String, dynamic>>.generate(
        8,
        (index) => {
          'deviceId': 'rift-trusted-$index',
          'displayName': 'Trusted Device $index',
          'platform': index.isEven ? 'android' : 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['presence.basic'],
        },
      );

    for (final size in const [
      Size(420, 600),
      Size(800, 600),
      Size(1200, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: Provider<JsonRpcRiftClient>.value(
            value: client,
            child: const TrustedDevicesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'viewport $size');
      expect(find.text('Trusted Device 0'), findsOneWidget);
      if (size.width >= 1024) {
        expect(
            find.byKey(const ValueKey('desktop-device-hub')), findsOneWidget);
        expect(
          tester
              .getSize(
                find.byKey(
                  const ValueKey('trusted-orbit-peer-rift-trusted-0'),
                ),
              )
              .height,
          lessThanOrEqualTo(126),
        );
      } else {
        expect(find.text('8 Devices'), findsOneWidget);
        expect(
          tester
              .getSize(
                find.byKey(
                  const ValueKey('trusted-peer-card-rift-trusted-0'),
                ),
              )
              .height,
          lessThanOrEqualTo(72),
        );
      }
    }
  });

  testWidgets(
      'TrustedDevicesScreen auto-starts discovery when trusted peers exist but discovery is offline',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient()
      ..isDiscovering = false
      ..discoveredPeers = const [];

    await tester.pumpWidget(MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const TrustedDevicesScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.startDiscoveryCallCount, 1);
  });

  testWidgets('Nearby Devices empty frame is taller on mobile',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = FakeJsonRpcRiftClient()..discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();

    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('nearby-devices-list')),
          )
          .height,
      greaterThanOrEqualTo(80),
    );
    expect(
      find.text('Looking for devices on your local network…'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.wifi_find), findsOneWidget);
  });

  testWidgets(
      'mobile Find Device action appears only while Nearby is offscreen',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 600));
    final client = FakeJsonRpcRiftClient()
      ..trustedPeers = List<Map<String, dynamic>>.generate(
        8,
        (index) => {
          'deviceId': 'rift-trusted-$index',
          'displayName': 'Trusted Device $index',
          'platform': 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': <String>[],
        },
      )
      ..discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final nearby = find.text('Nearby Devices');
    expect(tester.getTopLeft(nearby).dy, greaterThan(600));

    final findDeviceAction =
        find.byKey(const ValueKey('find-device-floating-action'));
    expect(findDeviceAction, findsOneWidget);

    await tester.tap(findDeviceAction);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(nearby).dy, lessThan(600));
    expect(
      find.byKey(const ValueKey('find-device-floating-action')),
      findsNothing,
    );
  });

  testWidgets('mobile Find Device action stays hidden while Nearby is visible',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final client = FakeJsonRpcRiftClient()
      ..trustedPeers = const []
      ..discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nearby Devices'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('find-device-floating-action')),
      findsNothing,
    );
  });

  testWidgets('desktop exposes Trusted and Nearby hub modes',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    final client = FakeJsonRpcRiftClient();

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1200, 800)),
          child: Provider<JsonRpcRiftClient>.value(
            value: client,
            child: const TrustedDevicesScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-device-hub')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-hub-mode-trusted')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('device-hub-mode-nearby')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('device-hub-local-core')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-trusted')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('nearby-orbit-peer-rift-discovered')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('device-detail-empty')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('device-hub-mode-nearby')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-hub-local-core')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('nearby-orbit-peer-rift-discovered')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-trusted')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('find-device-floating-action')),
      findsNothing,
    );
  });

  testWidgets('explicitly disabled discovery stays off until restarted',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    final client = FakeJsonRpcRiftClient()..discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1200, 800)),
          child: Provider<JsonRpcRiftClient>.value(
            value: client,
            child: const TrustedDevicesScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('device-hub-mode-nearby')));
    await tester.pumpAndSettle();

    final discoverySwitch =
        find.byKey(const ValueKey('desktop-discovery-switch'));
    await tester.tap(discoverySwitch);
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.stopDiscoveryCallCount, 1);
    expect(client.startDiscoveryCallCount, 0);
    expect(find.text('Discovery paused'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nearby-start-discovery')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.startDiscoveryCallCount, 1);
  });

  testWidgets('desktop manual connection keeps the existing pairing flow',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final client = FakeJsonRpcRiftClient()..discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-hub-mode-nearby')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('desktop-manual-connect')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('desktop-manual-device-address')),
      '192.168.1.60:12001',
    );
    await tester.tap(
      find.byKey(const ValueKey('desktop-manual-connect-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(client.manualPairAddress, '192.168.1.60');
    expect(client.manualPairPort, 12001);
    expect(
      find.byKey(
        const ValueKey('nearby-pairing-focus-192.168.1.60:12001'),
      ),
      findsOneWidget,
    );
    expect(find.text('Pairing Request'), findsOneWidget);
  });

  testWidgets('desktop management keeps blocked peer controls available',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final client = FakeJsonRpcRiftClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-blocked',
          'displayName': 'Blocked Peer',
          'platform': 'linux',
          'trustState': 'blocked',
          'presence': 'offline',
        },
      ]
      ..discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('desktop-device-management')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Blocked Peer'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Unblock'));
    await tester.pumpAndSettle();
    expect(find.text('Unblock device?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Unblock'));
    await tester.pumpAndSettle();

    expect(client.unblockCalled, isTrue);
  });

  testWidgets('manual connection expands inline and starts secure pairing',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 700));
    final client = FakeJsonRpcRiftClient()..discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('manual-connect-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual-connect-panel')), findsOneWidget);
    expect(
      find.textContaining('still verify the device before trusting it'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('manual-device-address')),
      '192.168.1.50:12000',
    );
    final connectButton = find.byKey(const ValueKey('manual-connect-button'));
    await tester.ensureVisible(connectButton);
    await tester.tap(connectButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(client.manualPairAddress, '192.168.1.50');
    expect(client.manualPairPort, 12000);
  });

  testWidgets('TrustedDevicesScreen does not show revoked peers in device list',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = const [];
    client.discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Former Peer'), findsNothing);
    expect(find.text('Reset'), findsNothing);
  });

  testWidgets('TrustedDevicesScreen can cancel a pairing pending peer',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-pending',
        'displayName': 'Pending Peer',
        'platform': 'android',
        'trustState': 'pairing_pending',
        'presence': 'offline',
        'capabilities': <String>[],
      }
    ];
    client.discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel').first);
    await tester.pumpAndSettle();
    expect(find.text('Cancel pairing?'), findsOneWidget);

    await tester.tap(find.text('Cancel pairing'));
    await tester.pumpAndSettle();
    expect(client.rejectCalled, isTrue);
    expect(find.text('PENDING'), findsWidgets);
  });

  testWidgets(
      'TrustedDevicesScreen hides discovered entry once peer is trusted',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-shared',
        'displayName': 'Linux Box',
        'platform': 'linux',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['presence.basic'],
      }
    ];
    client.discoveredPeers = [
      {
        'deviceId': 'rift-shared',
        'displayName': 'Linux Box',
        'platform': 'linux',
        'address': '192.168.1.20',
        'port': 9140,
        'trustState': 'discovered',
      },
      {
        'deviceId': 'rift-pending',
        'displayName': 'Pending Box',
        'platform': 'android',
        'address': '192.168.1.21',
        'port': 9141,
        'trustState': 'pairing_pending',
      }
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Linux Box'), findsOneWidget);
    expect(find.text('Pair'), findsNothing);
    expect(find.text('Pending Box'), findsNothing);
  });

  testWidgets(
      'TrustedDevicesScreen refreshes discovered peer into trusted peer on trust change',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = const [];
    client.discoveredPeers = [
      {
        'deviceId': 'rift-transition',
        'displayName': 'Phone',
        'platform': 'android',
        'address': '192.168.1.50',
        'port': 11112,
        'trustState': 'discovered',
      }
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);

    client.trustedPeers = [
      {
        'deviceId': 'rift-transition',
        'displayName': 'Phone',
        'platform': 'android',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['presence.basic'],
      }
    ];
    client.discoveredPeers = const [];

    await client.emitTrustChanged({
      'deviceId': 'rift-transition',
      'previousState': 'pairing_pending',
      'newState': 'trusted',
      'reason': 'pairing.completed',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('TRUSTED'), findsNothing);
    expect(find.text('ONLINE'), findsOneWidget);
    expect(find.text('Pair'), findsNothing);
  });

  testWidgets(
      'TrustedDevicesScreen shows presence indicators and capability badges',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-capable',
        'displayName': 'Linux Workstation',
        'platform': 'linux',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': [
          'presence.basic',
          'clipboard.offer_fetch',
          'security.event_log'
        ],
      }
    ];
    client.discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Presence indicator
    expect(find.text('Linux Workstation'), findsOneWidget);
    expect(find.text('ONLINE'), findsOneWidget);
    expect(find.byIcon(Icons.computer), findsWidgets);
  });

  testWidgets(
      'TrustedDevicesScreen refreshes trusted peer presence without extra daemon events',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-refresh',
        'displayName': 'Desk Node',
        'platform': 'windows',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['presence.basic'],
      }
    ];
    client.discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ONLINE'), findsOneWidget);

    client.trustedPeers = [
      {
        'deviceId': 'rift-refresh',
        'displayName': 'Desk Node',
        'platform': 'windows',
        'trustState': 'trusted',
        'presence': 'offline',
        'capabilities': ['presence.basic'],
      }
    ];

    final callsBeforeRefresh = client.listTrustedPeersCallCount;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(client.listTrustedPeersCallCount, greaterThan(callsBeforeRefresh));
    expect(find.text('OFFLINE'), findsOneWidget);
  });

  testWidgets(
      'TrustedDevicesScreen stops presence polling while covered by another route',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-covered',
        'displayName': 'Covered Peer',
        'platform': 'linux',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['presence.basic'],
      }
    ];
    client.discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final callsBeforeCover = client.listTrustedPeersCallCount;

    Navigator.of(tester.element(find.byType(TrustedDevicesScreen))).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Covered route')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(find.text('Covered route'), findsOneWidget);
    expect(client.listTrustedPeersCallCount, equals(callsBeforeCover));
  });

  testWidgets('TrustedDevicesScreen chooses icons from platform field',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-android',
        'displayName': 'Pixel',
        'platform': 'android',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['presence.basic'],
      },
      {
        'deviceId': 'rift-linux',
        'displayName': 'Linux Box',
        'platform': 'linux',
        'trustState': 'trusted',
        'presence': 'offline',
        'capabilities': <String>[],
      },
      {
        'deviceId': 'rift-windows',
        'displayName': 'Windows Box',
        'platform': 'windows',
        'trustState': 'trusted',
        'presence': 'offline',
        'capabilities': <String>[],
      },
      {
        'deviceId': 'rift-macos',
        'displayName': 'Mac Box',
        'platform': 'macos',
        'trustState': 'trusted',
        'presence': 'offline',
        'capabilities': <String>[],
      },
      {
        'deviceId': 'rift-mystery',
        'displayName': 'Mystery Box',
        'platform': 'unknown',
        'trustState': 'trusted',
        'presence': 'offline',
        'capabilities': <String>[],
      },
    ];
    client.discoveredPeers = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.smartphone), findsOneWidget);
    expect(find.byIcon(Icons.desktop_windows), findsAtLeastNWidgets(1));
    expect(find.byIcon(Icons.laptop_mac), findsOneWidget);
    expect(find.byIcon(Icons.computer), findsAtLeastNWidgets(1));
    expect(find.text('Mystery Box'), findsOneWidget);
    expect(find.byIcon(Icons.devices), findsOneWidget);
  });

  testWidgets('desktop pairing stays inside the Nearby scene',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = FakeJsonRpcRiftClient()
      ..discoveredPeers = [
        {
          'deviceId': 'rift-discovered-peer',
          'displayName': 'Discovered Laptop',
          'platform': 'linux',
          'presence': 'online',
          'trustState': 'discovered',
        }
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('device-hub-mode-nearby')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('nearby-orbit-peer-rift-discovered-peer')),
    );
    await tester.pumpAndSettle();

    final pairButton = find.byKey(const ValueKey('nearby-pair-action'));
    expect(pairButton, findsOneWidget);
    await tester.tap(pairButton);
    await tester.pump();
    await tester.pump();

    expect(client.startedPairingDeviceId, 'rift-discovered-peer');
    expect(
      find.byKey(
        const ValueKey('nearby-pairing-focus-rift-discovered-peer'),
      ),
      findsOneWidget,
    );
    expect(find.text('Pairing Request'), findsOneWidget);

    client.trustedPeers = [
      {
        'deviceId': 'rift-discovered-peer',
        'displayName': 'Discovered Laptop',
        'platform': 'linux',
        'presence': 'online',
        'trustState': 'pairing_pending',
      }
    ];

    await client.emitTrustChanged({
      'deviceId': 'rift-discovered-peer',
      'newState': 'pairing_pending',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Pairing Request'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.rejectCalled, isTrue);
    expect(find.text('Pairing Request'), findsNothing);
    expect(
      find.byKey(const ValueKey('nearby-orbit-overview')),
      findsOneWidget,
    );
  });

  testWidgets('desktop pairing success migrates peer into Trusted orbit',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = FakeJsonRpcRiftClient()
      ..trustedPeers = const []
      ..discoveredPeers = [
        {
          'deviceId': 'rift-newly-trusted',
          'displayName': 'Pixel 9',
          'platform': 'android',
          'presence': 'online',
          'trustState': 'discovered',
        }
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('device-hub-mode-nearby')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('nearby-orbit-peer-rift-newly-trusted')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nearby-pair-action')));
    await tester.pump();
    await tester.pump();

    client
      ..trustedPeers = [
        {
          'deviceId': 'rift-newly-trusted',
          'displayName': 'Pixel 9',
          'platform': 'android',
          'presence': 'online',
          'trustState': 'trusted',
          'capabilities': ['presence.basic'],
        }
      ]
      ..discoveredPeers = const [];
    await client.emitPairingComplete({
      'deviceId': 'rift-newly-trusted',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'persistedAt': '2026-08-14T00:00:00Z',
    });
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey('nearby-pairing-success-rift-newly-trusted'),
      ),
      findsOneWidget,
    );
    expect(find.text('Paired successfully'), findsOneWidget);
    expect(find.text('Pairing Request'), findsNothing);

    await tester.pump(const Duration(milliseconds: 799));
    expect(find.text('Paired successfully'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-newly-trusted')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('recently-paired-orbit-peer-rift-newly-trusted'),
      ),
      findsOneWidget,
    );
    expect(find.text('Paired successfully'), findsNothing);

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey('recently-paired-orbit-peer-rift-newly-trusted'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-newly-trusted')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('device-hub-mode-nearby')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('nearby-orbit-peer-rift-newly-trusted')),
      findsNothing,
    );
  });

  testWidgets(
      'DeviceDetailScreen removed state invokes onClose when embedded on desktop',
      (WidgetTester tester) async {
    bool onCloseCalled = false;
    final client = FakeJsonRpcRiftClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: DeviceDetailScreen(
            peer: const {
              'deviceId': 'rift-peer-removed',
              'displayName': 'Removed Device',
              'trustState': 'revoked',
            },
            isOnline: false,
            onClose: () {
              onCloseCalled = true;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await client.emitTrustChanged({
      'deviceId': 'rift-peer-removed',
      'newState': 'revoked',
    });
    await tester.pump();

    expect(find.text('Back to home'), findsOneWidget);
    await tester.tap(find.text('Back to home'));
    await tester.pump();

    expect(onCloseCalled, isTrue);
  });

  testWidgets('desktop focus keeps nodes reachable while a panel is open',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    for (final windowSize in const [
      Size(1024, 768),
      Size(1400, 900),
    ]) {
      tester.view.physicalSize = windowSize;
      final client = FakeJsonRpcRiftClient()
        ..trustedPeers = [
          {
            'deviceId': 'rift-peer-focus',
            'displayName': 'Focus Peer',
            'platform': 'android',
            'trustState': 'trusted',
            'presence': 'online',
            'capabilities': [
              'device.status',
              'media.playback',
              'presence.basic',
            ],
            'deviceStatus': {
              'sourceDeviceId': 'rift-peer-focus',
              'batteryPercent': 64,
              'observedAt': '2026-07-29T00:00:00Z',
            },
          },
        ];

      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(windowSize),
          home: Provider<JsonRpcRiftClient>.value(
            value: client,
            child: const TrustedDevicesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('trusted-orbit-peer-rift-peer-focus')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('device-focus-node-identity')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('device-focus-panel-identity')),
        findsOneWidget,
        reason: 'viewport $windowSize',
      );

      await tester.tap(
        find.byKey(const ValueKey('device-focus-node-capabilities')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('device-focus-panel-capabilities')),
        findsOneWidget,
        reason: 'viewport $windowSize',
      );

      await tester.tap(
        find.byKey(const ValueKey('device-focus-node-media')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('device-focus-panel-media')),
        findsOneWidget,
        reason: 'viewport $windowSize',
      );
    }
  });

  testWidgets('desktop hub isolates and updates playback state by peer',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final redArtwork = await tester.runAsync(
      () => _solidArtwork(const Color(0xFFD62828)),
    );
    final blueArtwork = await tester.runAsync(
      () => _solidArtwork(const Color(0xFF2457D6)),
    );
    final client = FakeJsonRpcRiftClient()
      ..trustedPeers = [
        {
          'deviceId': 'peer-a',
          'displayName': 'Peer A',
          'platform': 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['media.playback'],
        },
        {
          'deviceId': 'peer-b',
          'displayName': 'Peer B',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['media.playback'],
        },
      ]
      ..mediaPlaybacks = [
        {
          'sourceDeviceId': 'peer-a',
          'playbackId': 'shared-session',
          'appName': 'Player A',
          'title': 'Track A',
          'playbackState': 'playing',
          'updatedAt': '2026-08-01T10:00:00Z',
          'artwork': redArtwork,
        },
        {
          'sourceDeviceId': 'peer-b',
          'playbackId': 'shared-session',
          'appName': 'Player B',
          'title': 'Track B',
          'playbackState': 'paused',
          'updatedAt': '2026-08-01T10:01:00Z',
          'artwork': {
            'mediaType': 'image/png',
            'dataBase64': base64Encode(const [1, 2, 3]),
          },
        },
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('orbit-peer-media-playing-peer-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('orbit-peer-media-paused-peer-b')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('orbit-peer-media-accented-peer-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('orbit-peer-media-accented-peer-b')),
      findsNothing,
    );
    expect(find.byType(MediaPlaybackActivityRing), findsOneWidget);

    await client.emitMediaUpdated({
      'sourceDeviceId': 'peer-a',
      'playbackId': 'shared-session',
      'appName': 'Player A',
      'title': 'Track A',
      'playbackState': 'paused',
      'updatedAt': '2026-08-01T10:02:00Z',
      'artwork': redArtwork,
    });
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('orbit-peer-media-playing-peer-a')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('orbit-peer-media-paused-peer-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('orbit-peer-media-accented-peer-a')),
      findsOneWidget,
    );
    expect(find.byType(MediaPlaybackActivityRing), findsNothing);
    final peerFinder = find.byKey(const ValueKey('trusted-orbit-peer-peer-a'));
    final redAccent =
        tester.widget<DeviceOrbitPeer>(peerFinder).peer.accentColor;
    expect(redAccent, isNotNull);
    expect(
      HSLColor.fromColor(redAccent!).hue,
      anyOf(lessThan(20), greaterThan(340)),
    );
    expect(
      tester
          .widget<AnimatedContainer>(
            find.descendant(
              of: peerFinder,
              matching: find.byType(AnimatedContainer),
            ),
          )
          .duration,
      const Duration(milliseconds: 500),
    );

    await client.emitMediaUpdated({
      'sourceDeviceId': 'peer-a',
      'playbackId': 'shared-session',
      'appName': 'Player A',
      'title': 'Track A Two',
      'playbackState': 'paused',
      'updatedAt': '2026-08-01T10:03:00Z',
      'artwork': blueArtwork,
    });
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final blueAccent =
        tester.widget<DeviceOrbitPeer>(peerFinder).peer.accentColor;
    expect(blueAccent, isNotNull);
    expect(HSLColor.fromColor(blueAccent!).hue, inInclusiveRange(200, 250));

    await client.emitMediaRemoved({
      'sourceDeviceId': 'peer-a',
      'playbackId': 'shared-session',
    });
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('orbit-peer-media-paused-peer-a')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('orbit-peer-media-accented-peer-a')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('orbit-peer-media-paused-peer-b')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('trusted-orbit-peer-peer-a')),
    );
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('device-focus-node-media')), findsOneWidget);
    expect(find.text('Nothing playing'), findsOneWidget);
  });

  testWidgets('desktop hub focuses trusted peers in place',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-peer-1',
        'displayName': 'Peer One',
        'platform': 'android',
        'trustState': 'trusted',
        'presence': 'online',
      },
      {
        'deviceId': 'rift-peer-2',
        'displayName': 'Peer Two',
        'platform': 'linux',
        'trustState': 'trusted',
        'presence': 'online',
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-hub-local-core')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-detail-empty')), findsNothing);
    expect(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-peer-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-peer-2')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-peer-1')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-core')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-focus-node-security')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('desktop-device-hub')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('device-focus-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-focus-view')), findsNothing);
    expect(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-peer-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('trusted-orbit-peer-rift-peer-2')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Peer Two'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
  });
}
