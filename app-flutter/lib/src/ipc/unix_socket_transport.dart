import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:stream_channel/stream_channel.dart';
import 'package:logging/logging.dart';
import 'ipc_transport.dart';
import 'bounded_line_splitter.dart';

class UnixSocketTransport implements IpcTransport {
  final String socketPath;
  Socket? _socket;

  UnixSocketTransport({this.socketPath = '/tmp/rift-daemon.sock'});

  @override
  Future<StreamChannel<String>> connect() async {
    final candidates = _candidateSocketPaths(socketPath);
    Object? lastError;
    for (final path in candidates) {
      try {
        _socket = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (_socket == null) {
      throw SocketException(
        'Connection failed. Tried: ${candidates.join(', ')}. Last error: $lastError',
      );
    }

    final stream = _socket!
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const BoundedLineSplitter());

    final controller = StreamController<String>();
    controller.stream.map((s) => '$s\n').transform(utf8.encoder).listen((data) {
      _socket?.add(data);
    }, onDone: () {
      _socket?.close();
    }, onError: (e, stackTrace) {
      final log = Logger('UnixSocketTransport');
      log.severe('socket sink error: $e\n$stackTrace');
      // Destroying the socket forces the stream to close, which will trigger
      // the JSON-RPC client's .listen() onDone/onError and start reconnect flow.
      _socket?.destroy();
    });

    return StreamChannel<String>(stream, controller.sink);
  }

  @override
  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
  }
}

List<String> _candidateSocketPaths(String configured) {
  // If caller set a custom path, try it first.
  final paths = <String>[configured];

  // Align with daemon-cs runtime bindings where possible:
  // - Linux: $XDG_RUNTIME_DIR/rift-daemon/v0.1.sock (primary)
  //          /tmp/rift-daemon-<uid>/v0.1.sock (fallback)
  // - macOS: $TMPDIR/rift-daemon/v0.1.sock (primary)
  // Keep /tmp/rift-daemon.sock as a convenient local mock fallback.
  final env = Platform.environment;
  final xdg = env['XDG_RUNTIME_DIR'];
  if (xdg != null && xdg.isNotEmpty) {
    paths.add('$xdg/rift-daemon/v0.1.sock');
  }

  final tmpdir = env['TMPDIR'];
  if (tmpdir != null && tmpdir.isNotEmpty) {
    // TMPDIR often ends with '/', but double slashes are fine for unix paths.
    paths.add('$tmpdir/rift-daemon/v0.1.sock');
  }

  final uid = env['UID'];
  if (uid != null && uid.isNotEmpty) {
    paths.add('/tmp/rift-daemon-$uid/v0.1.sock');
  }

  paths.add('/tmp/rift-daemon.sock');

  // De-dupe while preserving order.
  final seen = <String>{};
  return paths.where((p) => seen.add(p)).toList(growable: false);
}
