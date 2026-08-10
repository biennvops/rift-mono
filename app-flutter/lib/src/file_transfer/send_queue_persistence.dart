import 'package:rift/src/file_transfer/send_queue_panel.dart';

class PersistedSendQueueEntry {
  const PersistedSendQueueEntry({
    this.queueItemId,
    required this.localPath,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
    this.transferId,
    this.operationId,
    this.targetDeviceId,
    this.bytesTransferred = 0,
    this.errorMessage,
    this.autoRetryWhenPeerAvailable = false,
    this.status = SendQueueStatus.queued,
  });

  final String? queueItemId;
  final String localPath;
  final String fileName;
  final String mediaType;
  final int byteSize;
  final String? transferId;
  final String? operationId;
  final String? targetDeviceId;
  final int bytesTransferred;
  final String? errorMessage;
  final bool autoRetryWhenPeerAvailable;
  final SendQueueStatus status;

  Map<String, dynamic> toJson() {
    return {
      'queueItemId': queueItemId,
      'localPath': localPath,
      'fileName': fileName,
      'mediaType': mediaType,
      'byteSize': byteSize,
      'transferId': transferId,
      'operationId': operationId,
      'targetDeviceId': targetDeviceId,
      'bytesTransferred': bytesTransferred,
      'errorMessage': errorMessage,
      'autoRetryWhenPeerAvailable': autoRetryWhenPeerAvailable,
      'status': status.name,
    };
  }

  static PersistedSendQueueEntry? restoreFromJson(
    Map<String, dynamic> map, {
    required bool sourceExists,
    int? actualByteSize,
  }) {
    final localPath = map['localPath']?.toString();
    final fileName = map['fileName']?.toString();
    final mediaType = map['mediaType']?.toString();
    if (localPath == null ||
        localPath.isEmpty ||
        fileName == null ||
        fileName.isEmpty ||
        mediaType == null ||
        mediaType.isEmpty) {
      return null;
    }

    final rawByteSize = (map['byteSize'] as num?)?.toInt();
    final byteSize = sourceExists
        ? (actualByteSize ?? rawByteSize ?? 0)
        : (rawByteSize == null || rawByteSize < 0 ? 0 : rawByteSize);

    final statusName = map['status']?.toString();
    final originalStatus = SendQueueStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => SendQueueStatus.queued,
    );

    if (!sourceExists) {
      return PersistedSendQueueEntry(
        localPath: localPath,
        queueItemId: map['queueItemId']?.toString(),
        fileName: fileName,
        mediaType: mediaType,
        byteSize: byteSize,
        targetDeviceId: map['targetDeviceId']?.toString(),
        status: SendQueueStatus.failed,
        errorMessage: 'Source file no longer exists.',
      );
    }

    final shouldWaitForReconnect =
        originalStatus == SendQueueStatus.sending ||
            map['autoRetryWhenPeerAvailable'] == true;

    return PersistedSendQueueEntry(
      localPath: localPath,
      queueItemId: map['queueItemId']?.toString(),
      fileName: fileName,
      mediaType: mediaType,
      byteSize: byteSize,
      transferId: shouldWaitForReconnect ? null : map['transferId']?.toString(),
      operationId:
          shouldWaitForReconnect ? null : map['operationId']?.toString(),
      targetDeviceId: map['targetDeviceId']?.toString(),
      bytesTransferred: shouldWaitForReconnect
          ? 0
          : ((map['bytesTransferred'] as num?)?.toInt() ?? 0),
      errorMessage: shouldWaitForReconnect
          ? _waitingMessage(map['targetDeviceId']?.toString())
          : map['errorMessage']?.toString(),
      autoRetryWhenPeerAvailable: shouldWaitForReconnect,
      status: shouldWaitForReconnect
          ? SendQueueStatus.queued
          : originalStatus,
    );
  }

  static String _waitingMessage(String? targetDeviceId) {
    if (targetDeviceId == null || targetDeviceId.isEmpty) {
      return 'Ready to resume after reconnect.';
    }
    return 'Waiting to retry when $targetDeviceId is available again.';
  }
}
