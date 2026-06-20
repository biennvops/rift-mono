import 'dart:io';
import 'package:stream_channel/stream_channel.dart';

import 'ipc_transport.dart';
import 'named_pipe_transport.dart';
import 'unix_socket_transport.dart';

class TransportFactory {
  /// Creates the appropriate IPC transport based on the current platform.
  static IpcTransport create() {
    if (Platform.isWindows) {
      return NamedPipeTransport();
    } else if (Platform.isLinux || Platform.isMacOS) {
      return UnixSocketTransport();
    } else if (Platform.isAndroid) {
      // TODO: Obtain the actual SendPort from the Dart daemon background service.
      return _DummyTransport('Android background service SendPort not yet plumbed');
    }

    throw UnsupportedError('Platform not supported for Rift Daemon IPC');
  }
}

class _DummyTransport implements IpcTransport {
  final String message;
  _DummyTransport(this.message);

  @override
  Future<StreamChannel<String>> connect() {
    return Future.error(UnimplementedError(message));
  }

  @override
  Future<void> disconnect() async {}
}
