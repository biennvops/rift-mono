import 'dart:io';

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
      throw UnimplementedError('Android background service SendPort not yet plumbed');
    }

    throw UnsupportedError('Platform not supported for Rift Daemon IPC');
  }
}
