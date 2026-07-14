import 'dart:async';

import 'package:app_flutter/src/file_transfer/send_queue_entry.dart';
import 'package:app_flutter/src/file_transfer/send_queue_panel.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';

class LegacySendQueueCoordinator {
  const LegacySendQueueCoordinator();

  Map<String, List<SendQueueEntry>> groupRecoverableFilesByOnlinePeer({
    required Iterable<SendQueueEntry> files,
    required bool Function(String deviceId) isPeerOnline,
  }) {
    final grouped = <String, List<SendQueueEntry>>{};
    for (final file in files) {
      final deviceId = file.targetDeviceId;
      if (deviceId == null || deviceId.isEmpty || !isPeerOnline(deviceId)) {
        continue;
      }
      grouped.putIfAbsent(deviceId, () => <SendQueueEntry>[]).add(file);
    }
    return grouped;
  }

  Future<int> submitFilesToPeer({
    required JsonRpcRiftClient client,
    required String deviceId,
    required List<SendQueueEntry> files,
    required bool Function() isMounted,
    required void Function(void Function()) mutateUi,
    required Future<void> Function() persistQueue,
    required void Function(SendQueueEntry entry) onSubmitted,
  }) async {
    var submittedCount = 0;
    for (final staged in files) {
      if (!isMounted()) {
        return submittedCount;
      }

      final submitted = await _submitSingleFile(
        client: client,
        staged: staged,
        deviceId: deviceId,
        isMounted: isMounted,
        mutateUi: mutateUi,
        persistQueue: persistQueue,
      );
      if (!submitted || !isMounted()) {
        continue;
      }

      submittedCount += 1;
      onSubmitted(staged);
    }
    return submittedCount;
  }

  Future<bool> _submitSingleFile({
    required JsonRpcRiftClient client,
    required SendQueueEntry staged,
    required String deviceId,
    required bool Function() isMounted,
    required void Function(void Function()) mutateUi,
    required Future<void> Function() persistQueue,
  }) async {
    if (!isMounted()) {
      return false;
    }

    mutateUi(() {
      staged.status = SendQueueStatus.sending;
      staged.errorMessage = null;
      staged.targetDeviceId = deviceId;
      staged.bytesTransferred = 0;
      staged.autoRetryWhenPeerAvailable = false;
    });
    unawaited(persistQueue());

    try {
      final result = await client.offerFile(
        targetDeviceId: deviceId,
        localPath: staged.localPath,
        fileName: staged.fileName,
        mediaType: staged.mediaType,
      );
      if (!isMounted()) {
        return false;
      }
      mutateUi(() {
        staged.transferId = result['transferId']?.toString();
        staged.operationId = result['operationId']?.toString();
      });
      unawaited(persistQueue());
      return true;
    } catch (error) {
      if (!isMounted()) {
        return false;
      }
      mutateUi(() {
        staged.status = SendQueueStatus.failed;
        staged.errorMessage = JsonRpcRiftClient.formatDisplayError(error);
        staged.autoRetryWhenPeerAvailable = false;
      });
      unawaited(persistQueue());
      return false;
    }
  }
}
