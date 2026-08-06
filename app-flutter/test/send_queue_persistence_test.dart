import 'package:rift/src/file_transfer/send_queue_panel.dart';
import 'package:rift/src/file_transfer/send_queue_persistence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restore keeps queued item when source file still exists', () {
    final restored = PersistedSendQueueEntry.restoreFromJson(
      {
        'localPath': '/tmp/demo.txt',
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
        'byteSize': 5,
        'targetDeviceId': 'rift-peer-1',
        'status': 'queued',
        'autoRetryWhenPeerAvailable': false,
      },
      sourceExists: true,
      actualByteSize: 5,
    );

    expect(restored, isNotNull);
    expect(restored!.fileName, 'demo.txt');
    expect(restored.status, SendQueueStatus.queued);
    expect(restored.targetDeviceId, 'rift-peer-1');
    expect(restored.errorMessage, isNull);
  });

  test('restore marks missing source file as failed', () {
    final restored = PersistedSendQueueEntry.restoreFromJson(
      {
        'localPath': '/tmp/missing.txt',
        'fileName': 'missing.txt',
        'mediaType': 'text/plain',
        'byteSize': 42,
        'targetDeviceId': 'rift-peer-1',
        'status': 'queued',
      },
      sourceExists: false,
    );

    expect(restored, isNotNull);
    expect(restored!.status, SendQueueStatus.failed);
    expect(restored.errorMessage, 'Source file no longer exists.');
    expect(restored.autoRetryWhenPeerAvailable, isFalse);
  });

  test('restore converts in-flight item into waiting queued item', () {
    final restored = PersistedSendQueueEntry.restoreFromJson(
      {
        'localPath': '/tmp/demo.txt',
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
        'byteSize': 5,
        'targetDeviceId': 'rift-peer-1',
        'transferId': 'transfer-1',
        'operationId': 'operation-1',
        'bytesTransferred': 3,
        'status': 'sending',
      },
      sourceExists: true,
      actualByteSize: 5,
    );

    expect(restored, isNotNull);
    expect(restored!.status, SendQueueStatus.queued);
    expect(restored.autoRetryWhenPeerAvailable, isTrue);
    expect(restored.transferId, isNull);
    expect(restored.operationId, isNull);
    expect(restored.bytesTransferred, 0);
    expect(
      restored.errorMessage,
      'Waiting to retry when rift-peer-1 is available again.',
    );
  });
}
