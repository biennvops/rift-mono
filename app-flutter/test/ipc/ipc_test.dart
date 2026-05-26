import 'package:flutter_test/flutter_test.dart';
import 'package:app_flutter/ipc/ipc.dart';

void main() {
  test('IPC create/send/receive (spike)', () async {
    final ipc = IPC.create();

    // Listen for the first message
    final received = ipc.messages.first;

    await ipc.send('hello');

    final msg = await received;
    expect(msg.contains('hello'), isTrue);
  });
}
