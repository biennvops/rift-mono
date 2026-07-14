import 'package:app_flutter/src/file_transfer/send_queue_panel.dart';

class SendQueuePeerSummary {
  const SendQueuePeerSummary({
    required this.eligibleCount,
    required this.unassignedCount,
    required this.waitingCount,
    required this.failedCount,
  });

  final int eligibleCount;
  final int unassignedCount;
  final int waitingCount;
  final int failedCount;

  String actionLabel() {
    if (eligibleCount <= 0) {
      return 'Queue Empty';
    }
    if (unassignedCount > 0) {
      return 'Send Unassigned ($unassignedCount)';
    }
    return 'Send Targeted ($eligibleCount)';
  }

  String detailLabel() {
    final parts = <String>[];
    if (unassignedCount > 0) {
      parts.add('$unassignedCount unassigned');
    }
    if (waitingCount > 0) {
      parts.add('$waitingCount waiting');
    }
    if (failedCount > 0) {
      parts.add('$failedCount failed');
    }
    if (parts.isEmpty) {
      return 'No eligible queued items.';
    }
    return parts.join(' • ');
  }
}

class SendQueueSummaryEntry {
  const SendQueueSummaryEntry({
    required this.status,
    required this.targetDeviceId,
    required this.isWaitingForReconnect,
  });

  final SendQueueStatus status;
  final String? targetDeviceId;
  final bool isWaitingForReconnect;
}

class SendQueueSummary {
  static SendQueuePeerSummary forPeer({
    required String peerDeviceId,
    required List<SendQueueSummaryEntry> items,
  }) {
    var eligibleCount = 0;
    var unassignedCount = 0;
    var waitingCount = 0;
    var failedCount = 0;

    for (final item in items) {
      final hasSendableState = item.status == SendQueueStatus.queued ||
          item.status == SendQueueStatus.failed;
      if (!hasSendableState) {
        continue;
      }

      final targetDeviceId = item.targetDeviceId;
      final isUnassigned = targetDeviceId == null || targetDeviceId.isEmpty;
      final isEligible = isUnassigned || targetDeviceId == peerDeviceId;
      if (!isEligible) {
        continue;
      }

      eligibleCount += 1;
      if (isUnassigned) {
        unassignedCount += 1;
      }
      if (item.isWaitingForReconnect) {
        waitingCount += 1;
      }
      if (item.status == SendQueueStatus.failed) {
        failedCount += 1;
      }
    }

    return SendQueuePeerSummary(
      eligibleCount: eligibleCount,
      unassignedCount: unassignedCount,
      waitingCount: waitingCount,
      failedCount: failedCount,
    );
  }
}
