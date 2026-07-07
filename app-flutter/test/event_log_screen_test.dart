import 'dart:async';

import 'package:app_flutter/constants.dart';
import 'package:app_flutter/screens/event_log_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'test_utils/fake_transport.dart';

class FakeJsonRpcRiftClient extends JsonRpcRiftClient {
  FakeJsonRpcRiftClient() : super(FakeTransport());

  bool connected = true;
  final _securityEventController =
      StreamController<Map<String, dynamic>>.broadcast();
  List<Map<String, dynamic>> events = [
    {
      'eventId': 'evt-1',
      'eventType': 'pairing.completed',
      'severity': 'info',
      'peerDeviceId': 'rift-peer-1',
      'timestamp': '2026-06-23T12:00:00Z',
      'outcome': 'success',
    },
    {
      'eventId': 'evt-2',
      'eventType': 'auth.failed',
      'severity': 'error',
      'peerDeviceId': 'rift-peer-2',
      'timestamp': '2026-06-23T12:01:00Z',
      'outcome': 'failure',
      'failureReason': 'AuthenticationFailed',
    },
  ];

  @override
  bool get isConnected => connected;

  @override
  Stream<Map<String, dynamic>> get onSecurityEvent =>
      _securityEventController.stream;

  Future<void> emitSecurityEvent(Map<String, dynamic> event) async {
    _securityEventController.add(event);
  }

  @override
  Future<dynamic> queryEventLog({
    List<String>? eventTypes,
    List<String>? severities,
    String? peerDeviceId,
    String? since,
    int limit = 100,
    int offset = 0,
  }) async {
    Iterable<Map<String, dynamic>> filtered = events;
    if (severities != null && severities.isNotEmpty) {
      filtered = filtered.where(
        (event) => severities.contains(event['severity']),
      );
    }
    return {
      'events': filtered.toList(growable: false),
      'total': filtered.length,
    };
  }
}

void main() {
  testWidgets('EventLogScreen shows queried events', (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const EventLogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.eventLogTitle), findsOneWidget);
    expect(find.text('pairing.completed'), findsOneWidget);
    expect(find.text('auth.failed'), findsOneWidget);
    expect(find.text('AuthenticationFailed'), findsOneWidget);
  });

  testWidgets('EventLogScreen filters by severity', (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const EventLogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Errors'));
    await tester.pumpAndSettle();

    expect(find.text('auth.failed'), findsOneWidget);
    expect(find.text('pairing.completed'), findsNothing);
  });

  testWidgets('EventLogScreen updates live on security event notification',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const EventLogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await client.emitSecurityEvent({
      'eventId': 'evt-live',
      'eventType': 'trust.revoked',
      'severity': 'warning',
      'peerDeviceId': 'rift-peer-live',
      'timestamp': '2026-06-23T12:02:00Z',
      'outcome': 'success',
      'failureReason': 'User revoked trust',
    });
    await tester.pump();

    expect(find.text('trust.revoked'), findsOneWidget);
    expect(find.text('User revoked trust'), findsOneWidget);
  });
}
