import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:app_flutter/screens/pairing_screen.dart';

void main() {
  testWidgets('PairingScreen shows title and stub text', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: PairingScreen()));
    expect(find.text('Pairing'), findsOneWidget);
    expect(find.text('Pairing screen stub'), findsOneWidget);
  });
}
