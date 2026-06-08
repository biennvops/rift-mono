import 'dart:io';
import 'dart:isolate';

import 'ipc_transport.dart';
import 'named_pipe_transport.dart';
import 'unix_socket_transport.dart';
import 'isolate_transport.dart';

class TransportFactory {
  /// Creates the appropriate IPC transport based on the current platform.
  static IpcTransport create() {
    if (Platform.isWindows) {
      return NamedPipeTransport();
    } else if (Platform.isLinux || Platform.isMacOS) {
      return UnixSocketTransport();
    } else if (Platform.isAndroid) {
      // TODO: Obtain the actual SendPort from the Dart daemon background service.
      // For now, using a dummy to compile.
      return IsolateTransport(daemonSendPort: ReceivePort().sendPort);
    }

    throw UnsupportedError('Platform not supported for Rift Daemon IPC');
  }
}
