import 'dart:async';

import 'package:app_flutter/screens/local_activity_screen.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/ui/local_events_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class ActivityClient extends JsonRpcRiftClient {
  ActivityClient() : super(FakeTransport());

  final securityEvent = StreamController<Map<String, dynamic>>.broadcast();
  final notification = StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get isConnected => false;

  @override
  Stream<Map<String, dynamic>> get onSecurityEvent => securityEvent.stream;

  @override
  Stream<Map<String, dynamic>> get onNotificationPosted => notification.stream;

  Future<void> closeControllers() async {
    await securityEvent.close();
    await notification.close();
  }
}

void main() {
  testWidgets('activity contains Rift events but excludes mirrored inbox items',
      (tester) async {
    final client = ActivityClient();
    final notifier = LocalEventsNotifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.closeControllers);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<JsonRpcRiftClient>.value(value: client),
          ChangeNotifierProvider<LocalEventsNotifier>.value(value: notifier),
        ],
        child: const MaterialApp(home: LocalActivityScreen()),
      ),
    );

    expect(find.byType(AppBar), findsNothing);
    final constraints = tester.widget<ConstrainedBox>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConstrainedBox &&
            widget.constraints.maxWidth == 560 &&
            widget.constraints.maxHeight == 640,
      ),
    );
    expect(constraints.constraints.maxWidth, 560);
    expect(constraints.constraints.maxHeight, 640);

    client.securityEvent.add({
      'eventId': 'event-clipboard-1',
      'eventType': 'clipboard.offered',
      'peerDeviceId': 'rift-peer-1',
      'outcome': 'success',
    });
    client.notification.add({
      'notificationId': 'notification-1',
      'sourceDeviceId': 'rift-peer-1',
      'appName': 'Messages',
      'title': 'Should not appear',
    });
    await tester.pump();

    expect(find.text('Clipboard received'), findsOneWidget);
    expect(find.text('Should not appear'), findsNothing);
  });
}
