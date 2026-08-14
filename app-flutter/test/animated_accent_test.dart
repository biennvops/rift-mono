import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/widgets/animated_accent.dart';

void main() {
  testWidgets('AnimatedAccent interpolates between track colors',
      (WidgetTester tester) async {
    var target = const Color(0xFFD62828);
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AnimatedAccent(
              color: target,
              builder: (context, accent) => ColoredBox(
                key: const ValueKey('animated-accent-value'),
                color: accent,
                child: const SizedBox.square(dimension: 40),
              ),
            );
          },
        ),
      ),
    );

    Color currentColor() => tester
        .widget<ColoredBox>(
          find.byKey(const ValueKey('animated-accent-value')),
        )
        .color;

    expect(currentColor(), const Color(0xFFD62828));

    update(() => target = const Color(0xFF2457D6));
    await tester.pump();
    expect(currentColor(), const Color(0xFFD62828));

    await tester.pump(const Duration(milliseconds: 300));
    final intermediate = currentColor();
    expect(intermediate, isNot(const Color(0xFFD62828)));
    expect(intermediate, isNot(const Color(0xFF2457D6)));

    await tester.pumpAndSettle();
    expect(currentColor(), const Color(0xFF2457D6));
  });

  testWidgets('AnimatedAccent settles immediately with reduced motion',
      (WidgetTester tester) async {
    var target = const Color(0xFFD62828);
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return AnimatedAccent(
                color: target,
                builder: (context, accent) => ColoredBox(
                  key: const ValueKey('reduced-accent-value'),
                  color: accent,
                ),
              );
            },
          ),
        ),
      ),
    );

    update(() => target = const Color(0xFF2457D6));
    await tester.pump();

    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('reduced-accent-value')),
          )
          .color,
      const Color(0xFF2457D6),
    );
  });
}
