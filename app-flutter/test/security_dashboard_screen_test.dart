import 'dart:async';

import 'package:app_flutter/screens/security_dashboard_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class _FakeSecurityClient extends JsonRpcRiftClient {
  _FakeSecurityClient() : super(FakeTransport());

  final _securityController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _trustController = StreamController<Map<String, dynamic>>.broadcast();
  final _peerDiscoveredController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerLostController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  bool _isConnected = false;
  int connectCalls = 0;
  List<Map<String, dynamic>> trustedPeers = const [
    {
      'deviceId': 'rift-peer-1',
      'trustState': 'trusted',
    }
  ];
  List<Map<String, dynamic>> discoveredPeers = const [
    {
      'deviceId': 'rift-peer-2',
      'trustState': 'discovered',
    }
  ];
  List<Map<String, dynamic>> events = const [
    {
      'eventId': 'evt-1',
      'eventType': 'trust.transitioned',
      'severity': 'info',
      'timestamp': '2026-07-14T01:00:00Z',
      'outcome': 'success',
      'peerDeviceId': 'rift-peer-1',
    }
  ];

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<Map<String, dynamic>> get onSecurityEvent =>
      _securityController.stream;

  @override
  Stream<Map<String, dynamic>> get onTrustChanged => _trustController.stream;

  @override
  Stream<Map<String, dynamic>> get onPeerDiscovered =>
      _peerDiscoveredController.stream;

  @override
  Stream<Map<String, dynamic>> get onPeerLost => _peerLostController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    _isConnected = true;
    _connectionController.add(true);
  }

  @override
  Future<dynamic> listTrustedPeers() async => {'peers': trustedPeers};

  @override
  Future<dynamic> listDiscoveredPeers() async => {'peers': discoveredPeers};

  @override
  Future<dynamic> queryEventLog({
    List<String>? eventTypes,
    List<String>? severities,
    String? peerDeviceId,
    String? since,
    int limit = 100,
    int offset = 0,
  }) async =>
      {
        'events': events.skip(offset).take(limit).toList(growable: false),
      };
}

void main() {
  testWidgets(
    'SecurityDashboardScreen reconnects and loads data when opened disconnected',
    (tester) async {
      final client = _FakeSecurityClient();

      await tester.pumpWidget(
        MaterialApp(
          home: Provider<JsonRpcRiftClient>.value(
            value: client,
            child: const SecurityDashboardScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(client.connectCalls, 1);
      expect(find.text('Daemon not connected.'), findsNothing);
      expect(find.text('1'), findsWidgets);
      expect(find.text('No recent events'), findsNothing);
    },
  );

  testWidgets('full log button is separated from the recent events frame',
      (tester) async {
    final client = _FakeSecurityClient()..events = const [];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const SecurityDashboardScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final eventFrame = find
        .ancestor(
          of: find.text('No recent events'),
          matching: find.byType(Container),
        )
        .first;
    final fullLogButton = find.widgetWithText(OutlinedButton, 'VIEW FULL LOG');
    final gap = tester.getTopLeft(fullLogButton).dy -
        tester.getBottomLeft(eventFrame).dy;

    expect(gap, greaterThanOrEqualTo(12));
  });
}
