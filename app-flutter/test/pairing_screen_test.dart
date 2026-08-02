import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app_flutter/screens/pairing_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'test_utils/fake_transport.dart';

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
  String? startPairingByEndpointAddress;
  int? startPairingByEndpointPort;
  Object? startPairingError;
  Map<String, dynamic> deviceInfo = const {
    'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
  };
  Map<String, dynamic>? startPairingResultOverride;
  Map<String, dynamic>? startPairingByEndpointResultOverride;

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
    if (startPairingResultOverride != null) {
      return startPairingResultOverride!;
    }
    return {
      'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'peerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    };
  }

  @override
  Future<dynamic> getDeviceInfo() async => deviceInfo;

  @override
  Future<dynamic> startPairingByEndpoint(String address, int port) async {
    startPairingByEndpointAddress = address;
    startPairingByEndpointPort = port;
    if (startPairingError != null) {
      throw startPairingError!;
    }
    if (startPairingByEndpointResultOverride != null) {
      return startPairingByEndpointResultOverride!;
    }
    return {
      'deviceId': 'rift-manual-peer',
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
    await tester.pump();
    expect(find.textContaining('Pixel 9', findRichText: true), findsOneWidget);
    expect(find.text('No active pairing yet'), findsOneWidget);
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
    await tester.pump(const Duration(milliseconds: 500));

    await client.emitPairingRequest({
      'deviceId': 'rift-peer',
      'displayName': 'Windows Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 3));

    expect(find.textContaining('Windows Laptop', findRichText: true),
        findsOneWidget);
    expect(find.text('Compare fingerprints'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('WAITING...'), findsNothing);
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
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Compare fingerprints'), findsOneWidget);
    expect(find.text("This device's fingerprint"), findsOneWidget);
    expect(find.textContaining('fingerprint'), findsWidgets);
    expect(find.text('Waiting for peer...'), findsOneWidget);
  });

  testWidgets('PairingScreen can auto-start from a manual endpoint',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialEndpointAddress: '10.53.38.174',
            initialEndpointPort: 9140,
            initialDisplayName: '10.53.38.174:9140',
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(client.startPairingByEndpointAddress, '10.53.38.174');
    expect(client.startPairingByEndpointPort, 9140);
    expect(find.textContaining('rift-manual-peer', findRichText: true),
        findsOneWidget);
  });

  testWidgets(
      'PairingScreen refreshes title when endpoint pairing resolves peer name',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient()
      ..startPairingByEndpointResultOverride = {
        'deviceId': 'rift-manual-peer',
        'displayName': 'Windows Laptop',
        'fingerprint': 'LOCAL-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'peerFingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
        'expiresInMs': 120000,
      };

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialEndpointAddress: '10.53.38.174',
            initialEndpointPort: 9140,
            initialDisplayName: '10.53.38.174:9140',
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Windows Laptop', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('10.53.38.174:9140', findRichText: true),
        findsNothing);
  });

  testWidgets(
      'PairingScreen incoming request approve and reject call IPC methods',
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
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 3));
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

    final approveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Approve'),
    );
    expect(approveButton.onPressed, isNull);
  });

  testWidgets('PairingScreen keeps the Rift layout on a phone viewport',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
      'displayName': 'Android Phone 73',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump();

    expect(find.text('Pairing Request'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PairingScreen reacts to trust persisted transition',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
            autoStart: true,
            onClose: () {
              closed = true;
            },
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

    expect(closed, isTrue);
  });

  testWidgets('PairingScreen requester reject returns to previous screen',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
            initialPeerFingerprint:
                'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
            initialExpiresInMs: 120000,
            onClose: () {
              closed = true;
            },
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Reject'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(client.rejectedDeviceId, 'rift-peer');
    expect(closed, isTrue);
  });

  testWidgets(
      'PairingScreen recipient closes instead of showing success screen',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Provider<JsonRpcRiftClient>.value(
                          value: client,
                          child: const PairingScreen(),
                        ),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 500));

    await client.emitPairingRequest({
      'deviceId': 'rift-peer',
      'displayName': 'Windows Laptop',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump(const Duration(milliseconds: 500));

    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Approve'));
    await tester.pump(const Duration(milliseconds: 500));

    await client.emitTrustChanged({
      'deviceId': 'rift-peer',
      'newState': 'trusted',
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Pairing complete'), findsNothing);
  });

  testWidgets(
      'PairingScreen preserves local fingerprint when late pairing request arrives',
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
    await tester.pump(const Duration(milliseconds: 500));

    await client.emitPairingRequest({
      'deviceId': 'rift-peer',
      'displayName': 'Pixel 9',
      'fingerprint': 'PEER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('WAITING...'), findsNothing);
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
  });
}
