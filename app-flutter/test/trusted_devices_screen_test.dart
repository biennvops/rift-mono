import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/screens/trusted_devices_screen.dart';
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/ipc/ipc_transport.dart';
import 'package:stream_channel/stream_channel.dart';

class FakeTransport implements IpcTransport {
  @override Future<void> disconnect() async {}
  @override Future<StreamChannel<String>> connect() async => StreamChannel(Stream.empty(), StreamController<String>().sink);
}

class FakeJsonRpcRiftClient extends JsonRpcRiftClient {
  FakeJsonRpcRiftClient() : super(FakeTransport());
  final _pairingCompleteController = StreamController<Map<String, dynamic>>.broadcast();
  bool unblockCalled = false;
  bool revokeCalled = false;
  
  @override bool get isConnected => true;
  @override Stream<Map<String, dynamic>> get onPeerDiscovered => Stream.empty();
  @override Stream<Map<String, dynamic>> get onPeerLost => Stream.empty();
  @override Stream<Map<String, dynamic>> get onTrustChanged => Stream.empty();
  @override Stream<Map<String, dynamic>> get onPairingComplete => _pairingCompleteController.stream;
  @override Future<dynamic> listDiscoveredPeers() async => {
    'peers': [
      {
        'deviceId': 'rift-discovered',
        'address': '192.168.1.10',
        'port': 11112,
        'trustState': 'discovered',
      }
    ],
    'isDiscovering': true,
  };
  @override Future<dynamic> listTrustedPeers() async => {
    'peers': [
      {
        'deviceId': 'rift-trusted',
        'displayName': 'Windows Laptop',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['presence.basic'],
      }
    ]
  };
  @override Future<dynamic> startDiscovery() async => {'started': true};
  @override Future<dynamic> stopDiscovery() async => {'stopped': true};
  @override Future<dynamic> unblockPeer(String deviceId) async {
    unblockCalled = true;
    return {'unblocked': true};
  }
  @override Future<dynamic> revokeTrust(String deviceId, String reason) async {
    revokeCalled = true;
    return {'revoked': true};
  }
}

void main() {
  testWidgets('TrustedDevicesScreen shows title', (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const TrustedDevicesScreen(),
        ),
      )
    );
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.trustedDevicesTitle), findsNWidgets(2));
    expect(find.text('Windows Laptop'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
  });

  testWidgets('TrustedDevicesScreen confirms revoke action', (WidgetTester tester) async {
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
}
