import 'dart:async';

import 'package:app_flutter/screens/device_detail_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class FakeDeviceDetailClient extends JsonRpcRiftClient {
  FakeDeviceDetailClient() : super(FakeTransport());

  final _trustChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerLostController =
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

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onTrustChanged =>
      _trustChangedController.stream;

  @override
  Stream<Map<String, dynamic>> get onPeerLost => _peerLostController.stream;

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

  Future<void> emitTrustChanged(Map<String, dynamic> event) async {
    _trustChangedController.add(event);
  }

  Future<void> emitPeerLost(Map<String, dynamic> event) async {
    _peerLostController.add(event);
  }
}

void main() {
  Widget buildTestApp(FakeDeviceDetailClient client) {
    return MaterialApp(
      home: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: DeviceDetailScreen(
          peer: client.trustedPeers.first,
          isOnline: true,
        ),
      ),
    );
  }

  testWidgets(
      'DeviceDetailScreen shows removed state when trusted peer disappears',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(find.text('Pixel 9'), findsWidgets);
    expect(find.text('ONLINE'), findsOneWidget);

    client.trustedPeers = const [];
    await client.emitTrustChanged({
      'deviceId': 'rift-phone',
      'previousState': 'trusted',
      'newState': 'revoked',
      'reason': 'removed.remote',
    });
    await tester.pumpAndSettle();

    expect(find.text('Device unavailable'), findsOneWidget);
    expect(find.text('Pixel 9 is no longer available'), findsOneWidget);
    expect(find.text('Back to home'), findsOneWidget);
  });

  testWidgets(
      'DeviceDetailScreen marks peer offline when peer lost event arrives',
      (WidgetTester tester) async {
    final client = FakeDeviceDetailClient();

    await tester.pumpWidget(buildTestApp(client));
    await tester.pumpAndSettle();

    expect(find.text('ONLINE'), findsOneWidget);

    await client.emitPeerLost({'deviceId': 'rift-phone'});
    await tester.pumpAndSettle();

    expect(find.text('OFFLINE'), findsOneWidget);
    expect(find.text('Device unavailable'), findsNothing);
  });
}
