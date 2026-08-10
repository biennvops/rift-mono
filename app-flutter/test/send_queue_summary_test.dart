import 'package:rift/src/file_transfer/send_queue_panel.dart';
import 'package:rift/src/file_transfer/send_queue_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('summary prefers Send Unassigned when peer has unassigned items', () {
    final summary = SendQueueSummary.forPeer(
      peerDeviceId: 'rift-peer-1',
      items: const [
        SendQueueSummaryEntry(
          status: SendQueueStatus.queued,
          targetDeviceId: null,
          isWaitingForReconnect: false,
        ),
        SendQueueSummaryEntry(
          status: SendQueueStatus.failed,
          targetDeviceId: 'rift-peer-1',
          isWaitingForReconnect: false,
        ),
        SendQueueSummaryEntry(
          status: SendQueueStatus.queued,
          targetDeviceId: 'rift-peer-2',
          isWaitingForReconnect: false,
        ),
      ],
    );

    expect(summary.eligibleCount, 2);
    expect(summary.unassignedCount, 1);
    expect(summary.failedCount, 1);
    expect(summary.actionLabel(), 'Send Unassigned (1)');
    expect(summary.detailLabel(), '1 unassigned • 1 failed');
  });

  test('summary falls back to targeted wording when nothing is unassigned', () {
    final summary = SendQueueSummary.forPeer(
      peerDeviceId: 'rift-peer-1',
      items: const [
        SendQueueSummaryEntry(
          status: SendQueueStatus.queued,
          targetDeviceId: 'rift-peer-1',
          isWaitingForReconnect: true,
        ),
        SendQueueSummaryEntry(
          status: SendQueueStatus.failed,
          targetDeviceId: 'rift-peer-1',
          isWaitingForReconnect: false,
        ),
      ],
    );

    expect(summary.eligibleCount, 2);
    expect(summary.unassignedCount, 0);
    expect(summary.waitingCount, 1);
    expect(summary.failedCount, 1);
    expect(summary.actionLabel(), 'Send Targeted (2)');
    expect(summary.detailLabel(), '1 waiting • 1 failed');
  });

  test('summary reports empty state when peer has nothing eligible', () {
    final summary = SendQueueSummary.forPeer(
      peerDeviceId: 'rift-peer-1',
      items: const [
        SendQueueSummaryEntry(
          status: SendQueueStatus.sent,
          targetDeviceId: null,
          isWaitingForReconnect: false,
        ),
        SendQueueSummaryEntry(
          status: SendQueueStatus.queued,
          targetDeviceId: 'rift-peer-2',
          isWaitingForReconnect: false,
        ),
      ],
    );

    expect(summary.eligibleCount, 0);
    expect(summary.actionLabel(), 'Queue Empty');
    expect(summary.detailLabel(), 'No eligible queued items.');
  });
}
