import 'package:flutter_test/flutter_test.dart';

import 'package:app_flutter/main.dart';
import 'package:app_flutter/constants.dart';

void main() {
  testWidgets('RiftApp shows home title', (WidgetTester tester) async {
    await tester.pumpWidget(const RiftApp());

    expect(find.text(AppStrings.appTitle), findsOneWidget);
    expect(find.text(AppStrings.homeSubtitle), findsOneWidget);
  });
}
