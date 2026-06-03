import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:app_flutter/screens/pairing_screen.dart';
import 'package:app_flutter/constants.dart';

void main() {
  testWidgets('PairingScreen shows title', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: PairingScreen()));
    expect(find.text(AppStrings.pairingTitle), findsNWidgets(2));
  });
}
