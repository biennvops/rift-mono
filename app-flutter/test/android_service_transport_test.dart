import 'package:app_flutter/src/ipc/android_service_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buffers messages until the first listener attaches', () async {
    final incoming = BufferedBroadcastStream<String>();
    incoming.add('early');

    final received = <String>[];
    final subscription = incoming.stream.listen(received.add);
    await pumpEventQueue();

    incoming.add('late');
    await pumpEventQueue();

    expect(received, ['early', 'late']);
    await subscription.cancel();
    await incoming.close();
  });
}
