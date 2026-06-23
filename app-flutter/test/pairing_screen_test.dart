import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/screens/pairing_screen.dart';
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/ipc/ipc_transport.dart';
import 'package:stream_channel/stream_channel.dart';

class FakeTransport implements IpcTransport {
  @override
  Future<StreamChannel<String>> connect() async =>
      StreamChannel(Stream.empty(), StreamController<String>().sink);

  @override
  Future<void> disconnect() async {}
}

class FakeJsonRpcRiftClient extends JsonRpcRiftClient {
  FakeJsonRpcRiftClient() : super(FakeTransport());

  final _pairingRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _pairingCompleteController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _trustChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  String? approvedDeviceId;
  String? approvedFingerprint;
  String? rejectedDeviceId;
  Object? startPairingError;

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onPairingRequest =>
      _pairingRequestController.stream;

  @override
  Stream<Map<String, dynamic>> get onPairingComplete =>
      _pairingCompleteController.stream;

  @override
  Stream<Map<String, dynamic>> get onTrustChanged =>
      _trustChangedController.stream;

  Future<void> emitPairingRequest(Map<String, dynamic> event) async {
    _pairingRequestController.add(event);
  }

  Future<void> emitPairingComplete(Map<String, dynamic> event) async {
    _pairingCompleteController.add(event);
  }

  Future<void> emitTrustChanged(Map<String, dynamic> event) async {
    _trustChangedController.add(event);
  }

  @override
  Future<dynamic> startPairing(String deviceId) async {
    if (startPairingError != null) {
      throw startPairingError!;
    }
    return {
      'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'peerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    };
  }

  @override
  Future<dynamic> approvePairing(String deviceId, String fingerprint) async {
    approvedDeviceId = deviceId;
    approvedFingerprint = fingerprint;
    return {
      'trustedDeviceId': deviceId,
      'persistedAt': '2026-06-21T00:00:00Z',
    };
  }

  @override
  Future<dynamic> rejectPairing(String deviceId) async {
    rejectedDeviceId = deviceId;
    return {'rejected': true};
  }
}

void main() {
  testWidgets('PairingScreen shows pairing data for selected peer',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
          ),
        ),
      ),
    );
    expect(find.text(AppStrings.pairingTitle), findsOneWidget);
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('Start pairing'), findsOneWidget);
  });

  testWidgets('PairingScreen reacts to incoming pairing request notification',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(),
        ),
      ),
    );

    await client.emitPairingRequest({
      'deviceId': 'rift-peer',
      'displayName': 'Windows Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump();

    expect(find.text('Windows Laptop'), findsOneWidget);
    expect(find.text('Incoming pairing request'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('PairingScreen auto-start populates fingerprints',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Confirm fingerprint to continue'), findsOneWidget);
    expect(find.textContaining('PEER-AAAA-BBBB'), findsOneWidget);
    expect(find.textContaining('LOCAL-AAAA-BBBB'), findsOneWidget);
    final approveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Approve'));
    expect(approveButton.onPressed, isNull);
  });

  testWidgets('PairingScreen incoming request approve and reject call IPC methods',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(),
        ),
      ),
    );

    await client.emitPairingRequest({
      'deviceId': 'rift-peer',
      'displayName': 'Pixel 9',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump();

    await tester.tap(find.text('Approve'));
    await tester.pump();
    expect(client.approvedDeviceId, 'rift-peer');
    expect(client.approvedFingerprint,
        'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH');

    await tester.tap(find.text('Reject'));
    await tester.pump();
    expect(client.rejectedDeviceId, 'rift-peer');
  });

  testWidgets('PairingScreen shows expired state after countdown elapses',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(),
        ),
      ),
    );

    await client.emitPairingRequest({
      'deviceId': 'rift-peer',
      'displayName': 'Windows Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 1000,
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Pairing request expired'), findsOneWidget);
    expect(find.text('Expired'), findsOneWidget);
  });

  testWidgets('PairingScreen reacts to trust persisted transition',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();

    await client.emitTrustChanged({
      'deviceId': 'rift-peer',
      'newState': 'trusted',
    });
    await tester.pump();

    expect(find.text('Trust persisted'), findsOneWidget);
  });

  testWidgets('PairingScreen reacts to pairing closed transition',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();

    await client.emitTrustChanged({
      'deviceId': 'rift-peer',
      'newState': 'discovered',
    });
    await tester.pump();

    expect(find.text('Pairing closed'), findsOneWidget);
  });

  testWidgets('PairingScreen resets actions cleanly after start failure',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.startPairingError = Exception(
      'JSON-RPC error -32000: Failed to establish a secure session with peer',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Unable to start pairing'), findsOneWidget);
    expect(
      find.textContaining('Could not establish a secure session'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);

    final rejectButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Reject'),
    );
    expect(rejectButton.onPressed, isNull);
  });
}
