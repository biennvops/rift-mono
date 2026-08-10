import 'package:rift/src/file_transfer/send_queue_panel.dart';
import 'package:rift/src/file_transfer/send_queue_targeting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('eligible when item has no target yet', () {
    expect(
      SendQueueTargeting.isEligibleForPeer(
        status: SendQueueStatus.queued,
        targetDeviceId: null,
        peerDeviceId: 'rift-peer-1',
      ),
      isTrue,
    );
  });

  test('eligible when failed item already targets same peer', () {
    expect(
      SendQueueTargeting.isEligibleForPeer(
        status: SendQueueStatus.failed,
        targetDeviceId: 'rift-peer-1',
        peerDeviceId: 'rift-peer-1',
      ),
      isTrue,
    );
  });

  test('not eligible when item targets another peer', () {
    expect(
      SendQueueTargeting.isEligibleForPeer(
        status: SendQueueStatus.queued,
        targetDeviceId: 'rift-peer-1',
        peerDeviceId: 'rift-peer-2',
      ),
      isFalse,
    );
  });

  test('not eligible when item is already sending or sent', () {
    expect(
      SendQueueTargeting.isEligibleForPeer(
        status: SendQueueStatus.sending,
        targetDeviceId: null,
        peerDeviceId: 'rift-peer-1',
      ),
      isFalse,
    );
    expect(
      SendQueueTargeting.isEligibleForPeer(
        status: SendQueueStatus.sent,
        targetDeviceId: null,
        peerDeviceId: 'rift-peer-1',
      ),
      isFalse,
    );
  });
}
