import 'dart:async';

import 'package:rift/constants.dart';
import 'package:rift/screens/event_log_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/ui/local_events_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'test_utils/fake_transport.dart';

class FakeJsonRpcRiftClient extends JsonRpcRiftClient {
  FakeJsonRpcRiftClient() : super(FakeTransport());

  bool connected = true;
  int queryEventLogCallCount = 0;
  Completer<void>? queryBlock;
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
    await queryBlock?.future;
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

class DirectActivityClient extends FakeJsonRpcRiftClient {
  final trustChanged = StreamController<Map<String, dynamic>>.broadcast();
  final pairingRequest = StreamController<Map<String, dynamic>>.broadcast();
  final pairingComplete = StreamController<Map<String, dynamic>>.broadcast();
  final clipboardOffer = StreamController<Map<String, dynamic>>.broadcast();
  final clipboardExpired = StreamController<Map<String, dynamic>>.broadcast();
  final fileTransferFailed = StreamController<Map<String, dynamic>>.broadcast();
  final securityEvent = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get onSecurityEvent => securityEvent.stream;

  @override
  Stream<Map<String, dynamic>> get onTrustChanged => trustChanged.stream;

  @override
  Stream<Map<String, dynamic>> get onPairingRequest => pairingRequest.stream;

  @override
  Stream<Map<String, dynamic>> get onPairingComplete => pairingComplete.stream;

  @override
  Stream<Map<String, dynamic>> get onClipboardOffer => clipboardOffer.stream;

  @override
  Stream<Map<String, dynamic>> get onClipboardExpired =>
      clipboardExpired.stream;

  @override
  Stream<Map<String, dynamic>> get onFileTransferFailed =>
      fileTransferFailed.stream;

  Future<void> closeDirectControllers() async {
    await trustChanged.close();
    await pairingRequest.close();
    await pairingComplete.close();
    await clipboardOffer.close();
    await clipboardExpired.close();
    await fileTransferFailed.close();
    await securityEvent.close();
    await _connectionChangedController.close();
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

  test('LocalEventsNotifier loads completed pairing history', () async {
    final client = FakeJsonRpcRiftClient()
      ..events = [
        {
          'eventId': 'evt-pairing-complete',
          'eventType': 'pairing.completed',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-complete',
          'timestamp': '2026-06-23T12:00:00Z',
          'outcome': 'success',
        },
      ];
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client._connectionChangedController.close);

    await Future<void>.delayed(Duration.zero);

    expect(notifier.events.single.title, 'Pairing completed');
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

  test('LocalEventsNotifier ignores duplicate security Activity events',
      () async {
    final client = DirectActivityClient()..connected = false;
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeDirectControllers);

    client.pairingComplete.add({
      'deviceId': 'rift-peer-complete',
      'displayName': 'Complete Peer',
      'fingerprint': 'fingerprint-complete',
      'persistedAt': '2026-06-23T12:00:00Z',
    });
    client.securityEvent.add({
      'eventId': 'evt-pairing-complete',
      'eventType': 'pairing.completed',
      'severity': 'info',
      'peerDeviceId': 'rift-peer-complete',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'outcome': 'success',
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      notifier.events.where((event) => event.title == 'Pairing completed'),
      hasLength(1),
    );
  });

  test('LocalEventsNotifier reconciles subjectless pairing history', () async {
    final client = DirectActivityClient()..connected = false;
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeDirectControllers);

    client.pairingComplete.add({
      'deviceId': 'rift-peer-reconnect-complete',
      'fingerprint': 'fingerprint-reconnect',
      'persistedAt': '2026-06-23T12:00:00Z',
    });
    await Future<void>.delayed(Duration.zero);
    client.events = [
      {
        'eventId': 'evt-pairing-reconnect-complete',
        'eventType': 'pairing.completed',
        'severity': 'info',
        'peerDeviceId': 'rift-peer-reconnect-complete',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'outcome': 'success',
      },
    ];
    await client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);

    expect(
      notifier.events.where((event) => event.title == 'Pairing completed'),
      hasLength(1),
    );
  });

  test('LocalEventsNotifier handles C# direct live notifications', () async {
    final client = DirectActivityClient()..connected = false;
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeDirectControllers);

    client.trustChanged.add({
      'deviceId': 'rift-peer-trust',
      'newState': 'trusted',
    });
    client.pairingRequest.add({
      'deviceId': 'rift-peer-request',
      'displayName': 'Request Peer',
      'fingerprint': 'fingerprint-request',
    });
    client.pairingComplete.add({
      'deviceId': 'rift-peer-complete',
      'displayName': 'Complete Peer',
    });
    client.clipboardOffer.add({
      'offerId': 'offer-live',
      'sourceDeviceId': 'rift-peer-clipboard',
      'contentType': 'text/plain',
    });
    client.clipboardExpired.add({'offerId': 'offer-expired'});
    client.fileTransferFailed.add({
      'transferId': 'transfer-failed',
      'peerDeviceId': 'rift-peer-file',
      'fileName': 'failed.txt',
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      notifier.events.map((event) => event.title),
      containsAll([
        'Device trusted',
        'Pairing request',
        'Pairing completed',
        'Clipboard received',
        'Clipboard offer expired',
        'File transfer failed',
      ]),
    );
  });

  test('LocalEventsNotifier keeps distinct same-peer live events', () async {
    final client = DirectActivityClient()..connected = false;
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeDirectControllers);

    for (final offerId in ['offer-1', 'offer-2']) {
      client.clipboardOffer.add({
        'offerId': offerId,
        'sourceDeviceId': 'rift-peer-shared',
        'contentType': 'text/plain',
      });
      client.clipboardExpired.add({'offerId': offerId});
    }
    for (final transferId in ['transfer-1', 'transfer-2']) {
      client.fileTransferFailed.add({
        'transferId': transferId,
        'peerDeviceId': 'rift-peer-shared',
        'fileName': '$transferId.txt',
      });
    }
    await Future<void>.delayed(Duration.zero);

    expect(
      notifier.events.where((event) => event.title == 'Clipboard received'),
      hasLength(2),
    );
    expect(
      notifier.events
          .where((event) => event.title == 'Clipboard offer expired'),
      hasLength(2),
    );
    expect(
      notifier.events.where((event) => event.title == 'File transfer failed'),
      hasLength(2),
    );
  });

  test('LocalEventsNotifier reconciles subjectless history one to one',
      () async {
    final client = DirectActivityClient()
      ..events = [
        {
          'eventId': 'evt-existing',
          'eventType': 'connection.established',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-existing',
          'timestamp': '2026-06-23T12:00:00Z',
          'outcome': 'success',
        },
      ];
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeDirectControllers);

    await Future<void>.delayed(Duration.zero);
    client.clipboardOffer.add({
      'offerId': 'offer-reconnect-1',
      'sourceDeviceId': 'rift-peer-clipboard',
      'contentType': 'text/plain',
    });
    client.clipboardOffer.add({
      'offerId': 'offer-reconnect-2',
      'sourceDeviceId': 'rift-peer-clipboard',
      'contentType': 'text/plain',
    });
    await Future<void>.delayed(Duration.zero);
    expect(notifier.events, hasLength(3));

    client.events = [
      ...client.events,
      {
        'eventId': 'evt-clipboard-reconnect',
        'eventType': 'clipboard.offered',
        'severity': 'info',
        'peerDeviceId': 'rift-peer-clipboard',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'outcome': 'success',
      },
    ];
    await client.emitConnectionChanged(false);
    await client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.events, hasLength(3));
    expect(
      notifier.events.where((event) => event.title == 'Clipboard received'),
      hasLength(2),
    );
  });

  test('LocalEventsNotifier reconciles matching subjects one to one', () async {
    final client = DirectActivityClient()
      ..events = [
        {
          'eventId': 'evt-existing-subject',
          'eventType': 'connection.established',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-existing',
          'timestamp': '2026-06-23T12:00:00Z',
          'outcome': 'success',
        },
      ];
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeDirectControllers);

    await Future<void>.delayed(Duration.zero);
    client.clipboardOffer.add({
      'offerId': 'offer-matching',
      'sourceDeviceId': 'rift-peer-subject',
      'contentType': 'text/plain',
    });
    await Future<void>.delayed(Duration.zero);
    client.events = [
      ...client.events,
      {
        'eventId': 'evt-matching-subject',
        'eventType': 'clipboard.offered',
        'severity': 'info',
        'peerDeviceId': 'rift-peer-subject',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'outcome': 'success',
        'details': {'offerId': 'offer-matching'},
      },
    ];
    await client.emitConnectionChanged(false);
    await client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.events, hasLength(2));
    expect(
      notifier.events.where((event) => event.title == 'Clipboard received'),
      hasLength(1),
    );
  });

  test('LocalEventsNotifier preserves events arriving during history load',
      () async {
    final client = DirectActivityClient()
      ..connected = false
      ..queryBlock = Completer<void>()
      ..events = [
        {
          'eventId': 'evt-history-other-offer',
          'eventType': 'clipboard.offered',
          'severity': 'info',
          'peerDeviceId': 'rift-peer-clipboard',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'outcome': 'success',
        },
      ];
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeDirectControllers);

    await client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);
    client.clipboardOffer.add({
      'offerId': 'offer-during-query',
      'sourceDeviceId': 'rift-peer-clipboard',
      'contentType': 'text/plain',
    });
    await Future<void>.delayed(Duration.zero);
    client.queryBlock!.complete();
    await Future<void>.delayed(Duration.zero);

    expect(
      notifier.events.where((event) => event.title == 'Clipboard received'),
      hasLength(2),
    );
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
