import 'package:app_flutter/src/file_transfer/send_queue_panel.dart';

class SendQueueTargeting {
  static bool isEligibleForPeer({
    required SendQueueStatus status,
    required String? targetDeviceId,
    required String peerDeviceId,
  }) {
    final hasSendableState =
        status == SendQueueStatus.queued || status == SendQueueStatus.failed;
    if (!hasSendableState) {
      return false;
    }

    if (targetDeviceId == null || targetDeviceId.isEmpty) {
      return true;
    }

    return targetDeviceId == peerDeviceId;
  }
}
