import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rift/screens/device_detail_screen.dart';
import 'package:rift/screens/trusted_devices_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'test_utils/fake_transport.dart';

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
  bool unblockCalled = false;
  bool revokeCalled = false;
  bool resetRevokedCalled = false;
  bool rejectCalled = false;
  int startDiscoveryCallCount = 0;
  int stopDiscoveryCallCount = 0;
  String? manualPairAddress;
  int? manualPairPort;
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
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
      await tester.binding.setSurfaceSize(size);
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
      expect(find.text('8 Devices'), findsOneWidget);
      expect(find.text('Trusted Device 0'), findsOneWidget);
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

  testWidgets('desktop keeps Find Device in the header',
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

    expect(
      find.byKey(const ValueKey('find-device-header-action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('find-device-floating-action')),
      findsNothing,
    );
  });

  testWidgets('explicitly disabled discovery stays off until Find Device',
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

    final discoverySwitch = find.byType(Switch).first;
    await tester.ensureVisible(discoverySwitch);
    await tester.tap(discoverySwitch);
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.stopDiscoveryCallCount, 1);
    expect(client.startDiscoveryCallCount, 0);

    final findDeviceAction =
        find.byKey(const ValueKey('find-device-header-action'));
    await tester.ensureVisible(findDeviceAction);
    await tester.tap(findDeviceAction);
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.startDiscoveryCallCount, 1);
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

  testWidgets('pairing action opens standard PairingRequest dialog on desktop',
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

    final pairButton = find.widgetWithText(FilledButton, 'Pair');
    expect(pairButton, findsOneWidget);
    await tester.tap(pairButton);
    await tester.pump();

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

  testWidgets('desktop split view switches focus between device cards',
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

    // Initially shows placeholder
    expect(
        find.text('Select a device to view details or pair.'), findsOneWidget);

    // Tap Peer One
    await tester.tap(find.text('Peer One'));
    await tester.pumpAndSettle();

    expect(find.text('Peer One'), findsWidgets);
    expect(find.text('Select a device to view details or pair.'), findsNothing);
    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-focus-core')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-focus-node-security')),
      findsOneWidget,
    );
    expect(find.text('Authorized Trusted Peer'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('device-focus-node-identity')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('device-focus-panel-identity')),
      findsOneWidget,
    );

    // Tap Peer Two to switch focus
    await tester.tap(find.text('Peer Two'));
    await tester.pumpAndSettle();

    expect(find.text('Peer Two'), findsWidgets);
    expect(find.byKey(const ValueKey('device-focus-view')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-focus-panel-identity')),
      findsNothing,
    );
    expect(find.text('Authorized Trusted Peer'), findsNothing);
  });
}
