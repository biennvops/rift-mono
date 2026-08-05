import 'package:rift/src/file_transfer/legacy_send_queue_coordinator.dart';
import 'package:rift/src/file_transfer/send_queue_controller.dart';
import 'package:rift/src/file_transfer/send_queue_entry.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';

enum SendQueueRuntimeMode {
  daemonBacked,
  legacyLocal,
}

class SendQueueModeCoordinator {
  SendQueueModeCoordinator(
    this._sendQueue, [
    this._legacyQueueCoordinator = const LegacySendQueueCoordinator(),
  ]);

  final SendQueueController _sendQueue;
  final LegacySendQueueCoordinator _legacyQueueCoordinator;

  Future<SendQueueRuntimeMode> resolveMode() async {
    return await _sendQueue.supportsDaemonQueue()
        ? SendQueueRuntimeMode.daemonBacked
        : SendQueueRuntimeMode.legacyLocal;
  }

  Future<bool> isLegacyLocalQueueMode() async {
    return await resolveMode() == SendQueueRuntimeMode.legacyLocal;
  }

  Future<Map<String, List<SendQueueEntry>>> groupRecoverableLegacyFilesByPeer({
    required Iterable<SendQueueEntry> files,
    required bool Function(String deviceId) isPeerOnline,
  }) async {
    if (!await isLegacyLocalQueueMode()) {
      return const <String, List<SendQueueEntry>>{};
    }
    return _legacyQueueCoordinator.groupRecoverableFilesByOnlinePeer(
      files: files,
      isPeerOnline: isPeerOnline,
    );
  }

  Future<int> dispatchToPeer({
    required JsonRpcRiftClient client,
    required String deviceId,
    required bool Function() isMounted,
    required void Function(void Function()) mutateUi,
    required Future<void> Function() persistQueue,
    required void Function(SendQueueEntry entry) onLegacySubmitted,
  }) async {
    final dispatch = await _sendQueue.dispatchToPeer(deviceId);
    if (!dispatch.requiresLegacyDispatch) {
      return dispatch.submitted;
    }

    final legacySubmitted = await _legacyQueueCoordinator.submitFilesToPeer(
      client: client,
      deviceId: deviceId,
      files: dispatch.legacyItems,
      isMounted: isMounted,
      mutateUi: mutateUi,
      persistQueue: persistQueue,
      onSubmitted: onLegacySubmitted,
    );
    return dispatch.submitted + legacySubmitted;
  }

  Future<bool> retryFailedItem({
    required JsonRpcRiftClient client,
    required SendQueueEntry file,
    required bool peerExists,
    required bool Function() isMounted,
    required void Function(void Function()) mutateUi,
    required Future<void> Function() persistQueue,
    required void Function() onNeedsPeerSelection,
    required void Function(String deviceId) onPeerUnavailable,
    required void Function(SendQueueEntry entry) onLegacySubmitted,
  }) async {
    final deviceId = file.targetDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      await _sendQueue.retryItem(file);
      onNeedsPeerSelection();
      return true;
    }

    if (await resolveMode() == SendQueueRuntimeMode.daemonBacked) {
      await _sendQueue.retryItem(file);
      return true;
    }

    if (!peerExists) {
      onPeerUnavailable(deviceId);
      return false;
    }

    final submitted = await _legacyQueueCoordinator.submitFilesToPeer(
      client: client,
      deviceId: deviceId,
      files: [file],
      isMounted: isMounted,
      mutateUi: mutateUi,
      persistQueue: persistQueue,
      onSubmitted: onLegacySubmitted,
    );
    return submitted > 0;
  }
}
