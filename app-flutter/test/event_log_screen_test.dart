import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:app_flutter/screens/event_log_screen.dart';
import 'package:app_flutter/constants.dart';

void main() {
  testWidgets('EventLogScreen shows title', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: EventLogScreen()));
    expect(find.text(AppStrings.eventLogTitle), findsNWidgets(2));
  });
}
