import 'package:app_flutter/src/file_transfer/send_queue_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildPanel(
    List<SendQueueItemData> items, {
    void Function(int index)? onRemove,
    void Function(int index)? onRetry,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SendQueuePanel(
          items: items,
          onRemove: onRemove ?? (_) {},
          onRetry: onRetry ?? (_) {},
        ),
      ),
    );
  }

  testWidgets('SendQueuePanel renders multiple queued items',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildPanel(
        const [
          SendQueueItemData(
            fileName: 'demo-one.txt',
            mediaType: 'text/plain',
            byteSize: 12,
            status: SendQueueStatus.queued,
          ),
          SendQueueItemData(
            fileName: 'demo-two.jpg',
            mediaType: 'image/jpeg',
            byteSize: 2048,
            status: SendQueueStatus.queued,
          ),
        ],
      ),
    );

    expect(find.text('Send Queue'), findsOneWidget);
    expect(find.text('demo-one.txt'), findsOneWidget);
    expect(find.text('demo-two.jpg'), findsOneWidget);
    expect(find.text('QUEUED'), findsNWidgets(2));
  });

  testWidgets('SendQueuePanel exposes Retry action for failed item',
      (WidgetTester tester) async {
    var retriedIndex = -1;

    await tester.pumpWidget(
      buildPanel(
        const [
          SendQueueItemData(
            fileName: 'broken.txt',
            mediaType: 'text/plain',
            byteSize: 128,
            status: SendQueueStatus.failed,
            errorMessage: 'Simulated send failure',
          ),
        ],
        onRetry: (index) {
          retriedIndex = index;
        },
      ),
    );

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Simulated send failure'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retriedIndex, 0);
  });
}
