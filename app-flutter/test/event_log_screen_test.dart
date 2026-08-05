import 'dart:async';

import 'package:app_flutter/constants.dart';
import 'package:app_flutter/screens/event_log_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/ui/local_events_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'test_utils/fake_transport.dart';

class FakeJsonRpcRiftClient extends JsonRpcRiftClient {
  FakeJsonRpcRiftClient() : super(FakeTransport());

  bool connected = true;
  int queryEventLogCallCount = 0;
  final _connectionChangedController = StreamController<bool>.broadcast();
  final _securityEventController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<bool> get onConnectionChanged => _connectionChangedController.stream;
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

  Future<void> emitConnectionChanged(bool value) async {
    connected = value;
    _connectionChangedController.add(value);
  }

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
    queryEventLogCallCount += 1;
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
  test('LocalEventsNotifier seeds the feed from event history', () async {
    final client = FakeJsonRpcRiftClient()
      ..events = [
        {
          'eventId': 'evt-clipboard',
          'eventType': 'clipboard.offered',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-history',
          'timestamp': '2026-06-23T12:00:00Z',
          'outcome': 'success',
        },
      ];
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client._connectionChangedController.close);

    await Future<void>.delayed(Duration.zero);

    expect(notifier.events, hasLength(1));
    expect(notifier.events.single.title, 'Clipboard received');
    expect(notifier.unreadCount, 0);
  });

  test('LocalEventsNotifier retries history after connecting', () async {
    final client = FakeJsonRpcRiftClient()
      ..connected = false
      ..events = [
        {
          'eventId': 'evt-delayed',
          'eventType': 'clipboard.offered',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-delayed',
          'timestamp': '2026-06-23T12:00:00Z',
        },
      ];
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client._connectionChangedController.close);

    await Future<void>.delayed(Duration.zero);
    expect(notifier.events, isEmpty);

    await client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.events, hasLength(1));
    expect(notifier.events.single.title, 'Clipboard received');
  });

  test('LocalEventsNotifier replaces history after reconnecting', () async {
    final client = FakeJsonRpcRiftClient()
      ..events = [
        {
          'eventId': 'evt-before-outage',
          'eventType': 'connection.established',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-before',
          'timestamp': '2026-06-23T12:00:00Z',
          'outcome': 'success',
        },
      ];
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client._connectionChangedController.close);

    await Future<void>.delayed(Duration.zero);
    expect(notifier.events, hasLength(1));
    expect(client.queryEventLogCallCount, 1);

    await client.emitSecurityEvent(client.events.single);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.events, hasLength(1));

    client.events = [
      ...client.events,
      {
        'eventId': 'evt-during-outage',
        'eventType': 'connection.lost',
        'severity': 'warning',
        'peerDeviceId': 'rift-peer-during',
        'timestamp': '2026-06-23T12:01:00Z',
        'outcome': 'failure',
      },
    ];
    await client.emitConnectionChanged(false);
    await client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.events, hasLength(2));
    expect(notifier.events.first.title, 'Device disconnected');
    expect(client.queryEventLogCallCount, 2);

    await client.emitConnectionChanged(false);
    await client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.events, hasLength(2));
    expect(client.queryEventLogCallCount, 3);
  });

  testWidgets('EventLogScreen shows queried events',
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

    expect(find.text(AppStrings.eventLogTitle), findsOneWidget);
    expect(find.text('pairing.completed'), findsOneWidget);
    expect(find.text('auth.failed'), findsOneWidget);
    expect(find.text('AuthenticationFailed'), findsOneWidget);
    expect(find.text('Full system activity timeline.'), findsNothing);
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.scrolledUnderElevation, 0);
    expect(appBar.surfaceTintColor, Colors.transparent);
  });

  testWidgets('EventLogScreen uses canonical event descriptions and details',
      (WidgetTester tester) async {
    final client = FakeJsonRpcRiftClient()
      ..events = [
        {
          'eventId': 'evt-pairing-attempted',
          'eventType': 'pairing.attempted',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-pairing',
          'timestamp': '2026-06-23T12:00:00Z',
          'outcome': 'success',
          'details': {'direction': 'incoming'},
        },
        {
          'eventId': 'evt-connection-established',
          'eventType': 'connection.established',
          'severity': 'warning',
          'peerDeviceId': 'rift-peer-session',
          'timestamp': '2026-06-23T12:01:00Z',
          'outcome': 'success',
          'details': {'bindingTier': 'app-nonce'},
        },
        {
          'eventId': 'evt-clipboard',
          'eventType': 'clipboard.offered',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-clipboard',
          'timestamp': '2026-06-23T12:02:00Z',
          'outcome': 'success',
        },
        {
          'eventId': 'evt-file',
          'eventType': 'file_transfer.rejected',
          'severity': 'warning',
          'peerDeviceId': 'rift-peer-file',
          'timestamp': '2026-06-23T12:03:00Z',
          'outcome': 'denied',
          'failureReason': 'PolicyDenied',
        },
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Provider<JsonRpcRiftClient>.value(
          value: client,
          child: const EventLogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Pairing flow initiated with rift-peer-pairing'),
      findsOneWidget,
    );
    expect(find.textContaining('direction: incoming'), findsOneWidget);
    expect(find.textContaining('bindingTier: app-nonce'), findsOneWidget);
    expect(find.textContaining('Trust established'), findsNothing);
    expect(find.textContaining('AES-256-GCM'), findsNothing);
    expect(find.textContaining('version: 0.1.0'), findsNothing);

    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();

    expect(find.text('connection.established'), findsOneWidget);
    expect(find.text('pairing.attempted'), findsNothing);

    await tester.tap(find.text('Clipboard'));
    await tester.pumpAndSettle();

    expect(find.text('clipboard.offered'), findsOneWidget);
    expect(find.text('file_transfer.rejected'), findsNothing);

    await client.emitSecurityEvent({
      'eventId': 'evt-file-live',
      'eventType': 'file_transfer.rejected',
      'severity': 'warning',
      'peerDeviceId': 'rift-peer-live-file',
      'timestamp': '2026-06-23T12:04:00Z',
      'outcome': 'denied',
      'failureReason': 'PolicyDenied',
    });
    await tester.pump();

    expect(find.text('file_transfer.rejected'), findsNothing);
  });

  testWidgets('EventLogScreen filters by severity',
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

    await tester.ensureVisible(find.text('Errors'));
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
      'eventType': 'trust.removed',
      'severity': 'warning',
      'peerDeviceId': 'rift-peer-live',
      'timestamp': '2026-06-23T12:02:00Z',
      'outcome': 'success',
      'failureReason': 'User removed trust',
    });
    await tester.pump();

    expect(find.text('trust.removed'), findsOneWidget);
    expect(find.text('User removed trust'), findsOneWidget);
  });
}
