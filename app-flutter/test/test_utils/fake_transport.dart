import 'dart:async';

import 'package:rift/src/ipc/ipc_transport.dart';
import 'package:stream_channel/stream_channel.dart';

class FakeTransport implements IpcTransport {
  @override
  Future<StreamChannel<String>> connect() async =>
      StreamChannel(Stream.empty(), StreamController<String>().sink);

  @override
  Future<void> disconnect() async {}
}
