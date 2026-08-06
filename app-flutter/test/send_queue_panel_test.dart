import 'package:rift/src/file_transfer/send_queue_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildPanel(
    List<SendQueueItemData> items, {
    void Function(int index)? onCancel,
    void Function(int index)? onRetry,
    void Function(int index)? onRetarget,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SendQueuePanel(
          items: items,
          onCancel: onCancel ?? (_) {},
          onRetry: onRetry ?? (_) {},
          onRetarget: onRetarget ?? (_) {},
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
            targetLabel: 'Pixel 9 Pro',
          ),
          SendQueueItemData(
            fileName: 'demo-two.jpg',
            mediaType: 'image/jpeg',
            byteSize: 2048,
            status: SendQueueStatus.queued,
            targetLabel: 'Windows Desktop 07',
          ),
        ],
      ),
    );

    expect(find.text('Send Queue'), findsOneWidget);
    expect(find.text('demo-one.txt'), findsOneWidget);
    expect(find.text('demo-two.jpg'), findsOneWidget);
    expect(find.text('Target: Pixel 9 Pro'), findsOneWidget);
    expect(find.text('Target: Windows Desktop 07'), findsOneWidget);
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

  testWidgets(
      'SendQueuePanel shows waiting label for reconnectable queued item',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildPanel(
        const [
          SendQueueItemData(
            fileName: 'recoverable.txt',
            mediaType: 'text/plain',
            byteSize: 64,
            bytesTransferred: 32,
            status: SendQueueStatus.queued,
            errorMessage:
                'Connection lost. Waiting to retry when peer is available again.',
            isWaitingForReconnect: true,
          ),
        ],
      ),
    );

    expect(find.text('RESUMING'), findsOneWidget);
    expect(find.text('QUEUED'), findsNothing);
    expect(find.textContaining('Waiting to retry'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('SendQueuePanel exposes Choose Device for unavailable target',
      (WidgetTester tester) async {
    var retargetedIndex = -1;

    await tester.pumpWidget(
      buildPanel(
        const [
          SendQueueItemData(
            fileName: 'stuck.txt',
            mediaType: 'text/plain',
            byteSize: 128,
            status: SendQueueStatus.failed,
            targetLabel: 'Old Laptop',
            errorMessage:
                'Target device Old Laptop is no longer available for file transfer.',
            canRetarget: true,
          ),
        ],
        onRetarget: (index) {
          retargetedIndex = index;
        },
      ),
    );

    expect(find.text('Choose Device'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Choose Device'));
    await tester.pump();

    expect(retargetedIndex, 0);
  });

  testWidgets('SendQueuePanel exposes Cancel action for active transfer',
      (WidgetTester tester) async {
    var cancelledIndex = -1;

    await tester.pumpWidget(
      buildPanel(
        const [
          SendQueueItemData(
            fileName: 'active.txt',
            mediaType: 'text/plain',
            byteSize: 128,
            bytesTransferred: 64,
            status: SendQueueStatus.sending,
          ),
        ],
        onCancel: (index) {
          cancelledIndex = index;
        },
      ),
    );

    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();

    expect(cancelledIndex, 0);
  });
}
