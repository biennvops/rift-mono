import 'dart:io';

import 'package:app_flutter/src/file_transfer/send_queue_panel.dart';
import 'package:app_flutter/src/file_transfer/send_queue_persistence.dart';

class SendQueueEntry {
  SendQueueEntry({
    this.queueItemId,
    required this.localPath,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
  });

  final String? queueItemId;
  final String localPath;
  final String fileName;
  final String mediaType;
  final int byteSize;
  String? transferId;
  String? operationId;
  String? targetDeviceId;
  int bytesTransferred = 0;
  String? errorMessage;
  bool autoRetryWhenPeerAvailable = false;
  SendQueueStatus status = SendQueueStatus.queued;

  Map<String, dynamic> toPersistedMap() {
    return PersistedSendQueueEntry(
      queueItemId: queueItemId,
      localPath: localPath,
      fileName: fileName,
      mediaType: mediaType,
      byteSize: byteSize,
      transferId: transferId,
      operationId: operationId,
      targetDeviceId: targetDeviceId,
      bytesTransferred: bytesTransferred,
      errorMessage: errorMessage,
      autoRetryWhenPeerAvailable: autoRetryWhenPeerAvailable,
      status: status,
    ).toJson();
  }

  static Future<SendQueueEntry?> fromPersistedEntryMap(
    Map<String, dynamic> map,
  ) async {
    final localPath = map['localPath']?.toString();
    if (localPath == null || localPath.isEmpty) {
      return null;
    }
    final file = File(localPath);
    final exists = await file.exists();
    final restored = PersistedSendQueueEntry.restoreFromJson(
      map,
      sourceExists: exists,
      actualByteSize: exists ? await file.length() : null,
    );
    if (restored == null) {
      return null;
    }

    final entry = SendQueueEntry(
      queueItemId: restored.queueItemId,
      localPath: restored.localPath,
      fileName: restored.fileName,
      mediaType: restored.mediaType,
      byteSize: restored.byteSize,
    );
    entry.transferId = restored.transferId;
    entry.operationId = restored.operationId;
    entry.targetDeviceId = restored.targetDeviceId;
    entry.bytesTransferred = restored.bytesTransferred;
    entry.errorMessage = restored.errorMessage;
    entry.autoRetryWhenPeerAvailable = restored.autoRetryWhenPeerAvailable;
    entry.status = restored.status;
    return entry;
  }

  static SendQueueEntry? fromDaemonQueueMap(Map<String, dynamic> map) {
    final localPath = map['localPath']?.toString();
    final fileName = map['fileName']?.toString();
    final mediaType = map['mediaType']?.toString();
    final byteSize = (map['byteSize'] as num?)?.toInt();
    if (localPath == null ||
        localPath.isEmpty ||
        fileName == null ||
        fileName.isEmpty ||
        mediaType == null ||
        mediaType.isEmpty ||
        byteSize == null) {
      return null;
    }

    final entry = SendQueueEntry(
      queueItemId: map['queueItemId']?.toString(),
      localPath: localPath,
      fileName: fileName,
      mediaType: mediaType,
      byteSize: byteSize,
    );
    entry.transferId = map['lastTransferId']?.toString();
    entry.operationId = map['currentOperationId']?.toString();
    entry.targetDeviceId = map['targetDeviceId']?.toString();
    entry.errorMessage = map['failureMessage']?.toString();
    entry.status = _statusFromDaemon(map['status']?.toString());
    entry.autoRetryWhenPeerAvailable = entry.status == SendQueueStatus.queued &&
        (map['status']?.toString() == 'waiting_for_peer');
    return entry;
  }

  static SendQueueStatus _statusFromDaemon(String? status) {
    switch (status?.toLowerCase()) {
      case 'waiting_for_target':
      case 'queued':
      case 'waiting_for_peer':
      case 'dispatching':
        return SendQueueStatus.queued;
      case 'sending':
        return SendQueueStatus.sending;
      case 'sent':
        return SendQueueStatus.sent;
      case 'failed':
      case 'cancelled':
        return SendQueueStatus.failed;
      default:
        return SendQueueStatus.queued;
    }
  }
}
