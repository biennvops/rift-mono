import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rift/screens/pairing_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/platform/macos_notifications.dart';
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
    'deviceId': 'rift-local-device',
    'displayName': 'Local Device',
    'platform': 'linux',
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
  setUp(() {
    MacOSNotifications.debugIsMacOSOverride = false;
  });
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

    expect(find.text('Windows Laptop'), findsOneWidget);
    expect(
        find.text('Verify both identities before trusting.'), findsOneWidget);
    expect(find.text('Trust & Pair'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pairing-local-fingerprint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pairing-peer-fingerprint')),
      findsOneWidget,
    );
  });

  testWidgets('PairingScreen outgoing flow shows the full fingerprint',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient()
      ..startPairingResultOverride = {
        'deviceId': 'rift-peer',
        'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
        'peerFingerprint': 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
        'expiresInMs': 120000,
      };

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
    await tester.pump();

    expect(find.text('rift-local-device'), findsOneWidget);
    expect(find.text('rift-peer'), findsOneWidget);
    expect(
      find.text('CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ'),
      findsOneWidget,
    );
    expect(
      find.text('ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567'),
      findsOneWidget,
    );
  });

  testWidgets('PairingScreen incoming flow shows the full peer fingerprint',
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
      'fingerprint': 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
      'expiresInMs': 120000,
    });
    await tester.pump();

    expect(
      find.text('ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567'),
      findsOneWidget,
    );
    expect(find.text('Fingerprint'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('pairing-local-fingerprint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pairing-peer-fingerprint')),
      findsOneWidget,
    );
  });

  testWidgets(
      'PairingScreen keeps local loading separate from peer fingerprint',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient()
      ..deviceInfo = const {
        'deviceId': 'rift-local-device',
        'displayName': 'Local Device',
        'platform': 'linux',
      };

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen.incoming(
            deviceId: 'rift-peer',
            displayName: 'Peer Device',
            fingerprint: 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
            expiresInMs: 120000,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('pairing-local-fingerprint')),
          )
          .data,
      'Loading fingerprint…',
    );
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('pairing-peer-fingerprint')),
          )
          .data,
      'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
    );
  });

  testWidgets(
      'PairingScreen keeps peer loading separate from local fingerprint',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient()
      ..startPairingResultOverride = {
        'deviceId': 'rift-peer',
        'fingerprint': 'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
        'expiresInMs': 120000,
      };

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Peer Device',
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('pairing-local-fingerprint')),
          )
          .data,
      'CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ',
    );
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('pairing-peer-fingerprint')),
          )
          .data,
      'Loading fingerprint…',
    );
  });

  testWidgets('PairingScreen ignores unrelated incoming pairing requests',
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

    await client.emitPairingRequest({
      'deviceId': 'rift-other',
      'displayName': 'Unrelated Laptop',
      'fingerprint': 'OTHER-AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH',
      'expiresInMs': 120000,
    });
    await tester.pump();

    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('Unrelated Laptop'), findsNothing);
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

    expect(
        find.text('Verify both identities before trusting.'), findsOneWidget);
    expect(find.text('Fingerprint'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('pairing-local-fingerprint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pairing-peer-fingerprint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pairing-waiting-for-peer')),
      findsOneWidget,
    );
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
    expect(
      find.byKey(const ValueKey('pairing-peer-device-id')),
      findsOneWidget,
    );
    expect(find.text('rift-manual-peer'), findsWidgets);
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

    expect(find.text('Windows Laptop'), findsOneWidget);
    expect(find.text('10.53.38.174:9140'), findsNothing);
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
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Trust & Pair'),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.byKey(const ValueKey('pairing-approval-delay')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Trust & Pair'));
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
      find.widgetWithText(FilledButton, 'Trust & Pair'),
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

    expect(find.text('Pair devices'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pairing-verification-shell')),
      findsOneWidget,
    );
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

  testWidgets('PairingScreen reports embedded pairing completion',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    var closed = false;
    String? completedDeviceId;
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
            onCompleted: (deviceId) {
              completedDeviceId = deviceId;
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

    expect(completedDeviceId, 'rift-peer');
    expect(closed, isFalse);
    expect(
      find.byKey(const ValueKey('pairing-verification-shell')),
      findsOneWidget,
    );
    expect(find.text('Pairing complete'), findsOneWidget);
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
    await tester.tap(find.text('Cancel'));
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
    await tester.tap(find.text('Trust & Pair'));
    await tester.pump(const Duration(milliseconds: 500));

    await client.emitTrustChanged({
      'deviceId': 'rift-peer',
      'newState': 'trusted',
    });
    await tester.pump(const Duration(seconds: 1));

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

    final localFingerprint = tester.widget<SelectableText>(
      find.byKey(const ValueKey('pairing-local-fingerprint')),
    );
    expect(localFingerprint.data, isNot('Loading fingerprint…'));
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

  testWidgets(
      'PairingScreen close button invokes onClose callback on start failure',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();
    client.startPairingError = Exception(
      'JSON-RPC error -32000: Failed to establish a secure session with peer',
    );

    bool onCloseCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: PairingScreen(
            initialDeviceId: 'rift-peer',
            initialDisplayName: 'Pixel 9',
            autoStart: true,
            onClose: () {
              onCloseCalled = true;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Unable to start pairing'), findsOneWidget);
    final closeBtn = find.widgetWithText(FilledButton, 'Close');
    expect(closeBtn, findsOneWidget);

    await tester.tap(closeBtn);
    await tester.pumpAndSettle();

    expect(onCloseCalled, isTrue);
  });
}
