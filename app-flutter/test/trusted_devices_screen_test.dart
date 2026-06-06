import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:app_flutter/screens/trusted_devices_screen.dart';
import 'package:app_flutter/constants.dart';

void main() {
  testWidgets('TrustedDevicesScreen shows title', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TrustedDevicesScreen()));
    expect(find.text(AppStrings.trustedDevicesTitle), findsNWidgets(2));
  });
}
