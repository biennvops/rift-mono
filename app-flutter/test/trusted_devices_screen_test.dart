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
  
  @override bool get isConnected => false;
  @override Stream<Map<String, dynamic>> get onPeerDiscovered => Stream.empty();
  @override Stream<Map<String, dynamic>> get onPeerLost => Stream.empty();
  @override Stream<Map<String, dynamic>> get onTrustChanged => Stream.empty();
  @override Future<dynamic> listDiscoveredPeers() async => {'peers': []};
  @override Future<dynamic> listTrustedPeers() async => {'peers': []};
}

void main() {
  testWidgets('TrustedDevicesScreen shows title', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: FakeJsonRpcRiftClient(),
          child: const TrustedDevicesScreen(),
        ),
      )
    );
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.trustedDevicesTitle), findsNWidgets(1));
  });
}
