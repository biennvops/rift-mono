import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/ui/indexed_transition_stack.dart';

void main() {
  testWidgets('keeps child state when switching sections',
      (WidgetTester tester) async {
    var index = 0;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('counter-button-0')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(find.text('Count 1'), findsOneWidget);

    index = 1;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );
    await tester.pumpAndSettle();

    index = 0;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Count 1'), findsOneWidget);
  });

  testWidgets('retargets rapid changes and settles on the final index',
      (WidgetTester tester) async {
    var index = 0;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );

    for (final nextIndex in [1, 2, 3]) {
      index = nextIndex;
      await tester.pumpWidget(
        _Harness(
          index: index,
          onIndexChanged: (value) => index = value,
        ),
      );
      await tester.pump(const Duration(milliseconds: 24));
    }
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('section-3')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outgoing child ignores pointer input',
      (WidgetTester tester) async {
    var index = 0;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );

    index = 1;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));

    await tester.tap(
      find.byKey(const ValueKey('counter-button-0')),
      warnIfMissed: false,
    );
  });

  testWidgets('reduced motion switches without spatial transition',
      (WidgetTester tester) async {
    var index = 0;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _Harness(
          index: index,
          onIndexChanged: (value) => index = value,
        ),
      ),
    );

    index = 1;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _Harness(
          index: index,
          onIndexChanged: (value) => index = value,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('section-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same index is a no-op and dispose during transition is safe',
      (WidgetTester tester) async {
    var index = 0;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );
    index = 1;
    await tester.pumpWidget(
      _Harness(
        index: index,
        onIndexChanged: (value) => index = value,
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

class _Harness extends StatelessWidget {
  const _Harness({required this.index, required this.onIndexChanged});

  final int index;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: RiftIndexedTransitionStack(
          index: index,
          direction: index == 0 ? 1 : null,
          children: [
            _Counter(
              key: const ValueKey('section-0'),
              index: 0,
              onIndexChanged: onIndexChanged,
            ),
            _Counter(
              key: const ValueKey('section-1'),
              index: 1,
              onIndexChanged: onIndexChanged,
            ),
            _Counter(
              key: const ValueKey('section-2'),
              index: 2,
              onIndexChanged: onIndexChanged,
            ),
            _Counter(
              key: const ValueKey('section-3'),
              index: 3,
              onIndexChanged: onIndexChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _Counter extends StatefulWidget {
  const _Counter({
    super.key,
    required this.index,
    required this.onIndexChanged,
  });

  final int index;
  final ValueChanged<int> onIndexChanged;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var _count = 0;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton(
        key: ValueKey('counter-button-${widget.index}'),
        onPressed: () => setState(() => _count++),
        child: Text('Count $_count'),
      ),
    );
  }
}
