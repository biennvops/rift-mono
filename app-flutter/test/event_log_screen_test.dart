import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:app_flutter/screens/event_log_screen.dart';

void main() {
  testWidgets('EventLogScreen shows title and stub text', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: EventLogScreen()));
    expect(find.text('Event Log'), findsOneWidget);
    expect(find.text('Event log screen stub'), findsOneWidget);
  });
}
