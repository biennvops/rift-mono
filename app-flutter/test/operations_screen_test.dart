import 'package:rift/screens/operations_screen.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class FailingOperationsClient extends JsonRpcRiftClient {
  FailingOperationsClient() : super(FakeTransport());

  @override
  Future<dynamic> listOperations({int? limit, int? offset}) async =>
      throw StateError('Operations unavailable');

  @override
  Stream<Map<String, dynamic>> get onOperationTransition =>
      const Stream.empty();
}

void main() {
  testWidgets('operations load error is presented inside a themed card',
      (tester) async {
    final client = FailingOperationsClient();
    await tester.pumpWidget(
      Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const MaterialApp(home: OperationsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Failed to load operations'), findsOneWidget);
    expect(find.textContaining('Operations unavailable'), findsNothing);
    final errorIcon = find.byIcon(Icons.error_outline);
    expect(errorIcon, findsOneWidget);
    final iconContainer = tester.widget<Container>(
      find.ancestor(of: errorIcon, matching: find.byType(Container)).first,
    );
    final decoration = iconContainer.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(8));

    final framedContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Failed to load operations'),
            matching: find.byType(Container),
          )
          .last,
    );
    final frameDecoration = framedContainer.decoration! as BoxDecoration;
    final border = frameDecoration.border! as Border;
    expect(border.top.width, 1);
    expect(frameDecoration.color, Colors.white);
  });
}
