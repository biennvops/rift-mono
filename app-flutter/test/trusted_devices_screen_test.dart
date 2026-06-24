import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/screens/trusted_devices_screen.dart';
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
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
  List<Map<String, dynamic>> trustedPeers = [
    {
      'deviceId': 'rift-trusted',
      'displayName': 'Windows Laptop',
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
  Future<dynamic> listDiscoveredPeers() async => {
        'peers': discoveredPeers,
        'isDiscovering': false,
      };
  @override
  Future<dynamic> listTrustedPeers() async => {'peers': trustedPeers};
  @override
  Future<dynamic> startDiscovery() async => {'started': true};
  @override
  Future<dynamic> stopDiscovery() async => {'stopped': true};
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
    expect(find.text(AppStrings.trustedDevicesTitle), findsNWidgets(2));
    expect(find.text('Windows Laptop'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
  });

  testWidgets('TrustedDevicesScreen confirms revoke action',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Revoke trust'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke trust?'), findsOneWidget);

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(client.revokeCalled, isTrue);
  });

  testWidgets('TrustedDevicesScreen can reset a revoked peer',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-revoked',
        'displayName': 'Former Peer',
        'trustState': 'revoked',
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

    await tester.tap(find.byTooltip('Reset revoked peer'));
    await tester.pumpAndSettle();
    expect(find.text('Reset revoked peer?'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(client.resetRevokedCalled, isTrue);
  });

  testWidgets('TrustedDevicesScreen can cancel a pairing pending peer',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-pending',
        'displayName': 'Pending Peer',
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

    await tester.tap(find.byTooltip('Cancel pairing'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel pairing?'), findsOneWidget);

    await tester.tap(find.text('Cancel pairing'));
    await tester.pumpAndSettle();
    expect(client.rejectCalled, isTrue);
  });

  testWidgets('TrustedDevicesScreen hides discovered entry once peer is trusted',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-shared',
        'displayName': 'Linux Box',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['presence.basic'],
      }
    ];
    client.discoveredPeers = [
      {
        'deviceId': 'rift-shared',
        'displayName': 'Linux Box',
        'address': '192.168.1.20',
        'port': 9140,
        'trustState': 'discovered',
      },
      {
        'deviceId': 'rift-pending',
        'displayName': 'Pending Box',
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

  testWidgets('TrustedDevicesScreen refreshes discovered peer into trusted peer on trust change',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = const [];
    client.discoveredPeers = [
      {
        'deviceId': 'rift-transition',
        'displayName': 'Phone',
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
    expect(find.text('Trusted'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Pair'), findsNothing);
  });

  testWidgets('TrustedDevicesScreen shows peer as discoverable again after revoked peer is reset',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.trustedPeers = [
      {
        'deviceId': 'rift-resettable',
        'displayName': 'Tablet',
        'trustState': 'revoked',
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

    await tester.tap(find.byTooltip('Reset revoked peer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(client.resetRevokedCalled, isTrue);

    client.trustedPeers = const [];
    client.discoveredPeers = [
      {
        'deviceId': 'rift-resettable',
        'displayName': 'Tablet',
        'address': '192.168.1.55',
        'port': 11112,
        'trustState': 'discovered',
      }
    ];

    await client.emitTrustChanged({
      'deviceId': 'rift-resettable',
      'previousState': 'revoked',
      'newState': 'discovered',
      'reason': 'trust.reset',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Tablet'), findsOneWidget);
    expect(find.text('Discovered'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
  });
}
