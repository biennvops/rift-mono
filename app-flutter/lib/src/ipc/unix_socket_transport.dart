import 'dart:async';
import 'dart:io';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';
import 'streamjsonrpc_framer.dart';

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

    // C# daemon (StreamJsonRpc) uses header-delimited framing (Content-Length).
    // Use the same framing here so Flutter can talk to daemon-cs on Linux/macOS.
    return streamJsonRpcFramer(
      _socket!,
      _socket!,
    );
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

  final uid = _resolveUid();
  if (uid != null && uid.isNotEmpty) {
    paths.add('/tmp/rift-daemon-$uid/v0.1.sock');
  }

  paths.add('/tmp/rift-daemon.sock');

  // De-dupe while preserving order.
  final seen = <String>{};
  return paths.where((p) => seen.add(p)).toList(growable: false);
}

String? _resolveUid() {
  final envUid = Platform.environment['UID'];
  if (envUid != null && envUid.isNotEmpty) {
    return envUid;
  }
  try {
    final statusFile = File('/proc/self/status');
    if (!statusFile.existsSync()) {
      return null;
    }
    for (final line in statusFile.readAsLinesSync()) {
      if (!line.startsWith('Uid:')) continue;
      final parts = line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.length >= 2) {
        return parts[1];
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}
