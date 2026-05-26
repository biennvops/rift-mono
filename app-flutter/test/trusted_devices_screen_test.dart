import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:app_flutter/screens/trusted_devices_screen.dart';

void main() {
  testWidgets('TrustedDevicesScreen shows title and stub text', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TrustedDevicesScreen()));
    expect(find.text('Trusted Devices'), findsOneWidget);
    expect(find.text('Trusted devices screen stub'), findsOneWidget);
  });
}
