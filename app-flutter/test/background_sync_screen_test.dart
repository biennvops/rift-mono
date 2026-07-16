import 'package:app_flutter/screens/background_sync_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('BackgroundSyncScreen shows final review copy',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: BackgroundSyncScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.textContaining('Review'), findsOneWidget);
    expect(find.text('What this step means'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Accessibility remains out of scope'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Accessibility remains out of scope'), findsOneWidget);
    expect(find.text('Finish Setup'), findsOneWidget);
  });

  testWidgets('BackgroundSyncScreen marks onboarding complete',
      (WidgetTester tester) async {
    var finishCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: BackgroundSyncScreen(
          onFinish: (_) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('has_completed_onboarding', true);
            finishCalled = true;
          },
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish Setup'));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(finishCalled, isTrue);
    expect(prefs.getBool('has_completed_onboarding'), isTrue);
  });
}
