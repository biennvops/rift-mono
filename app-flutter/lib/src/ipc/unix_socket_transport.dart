import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';
import 'streamjsonrpc_framer.dart';

class UnixSocketTransport implements IpcTransport {
  final String? socketPath;
  Socket? _socket;

  UnixSocketTransport({this.socketPath});

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

@visibleForTesting
List<String> candidateSocketPathsForTesting({
  String? configured,
  Map<String, String>? environment,
  String? uidOverride,
}) =>
    _candidateSocketPaths(
      configured,
      environment: environment,
      uidOverride: uidOverride,
    );

List<String> _candidateSocketPaths(
  String? configured, {
  Map<String, String>? environment,
  String? uidOverride,
}) {
  final paths = <String>[];
  if (configured != null && configured.isNotEmpty) {
    paths.add(configured);
  }

  // Align with daemon-cs runtime bindings where possible:
  // - Linux: $XDG_RUNTIME_DIR/rift-daemon/v0.1.sock (primary)
  //          /tmp/rift-daemon-<uid>/v0.1.sock (fallback)
  // - macOS: $TMPDIR/rift-daemon/v0.1.sock (primary)
  final env = environment ?? Platform.environment;
  final xdg = env['XDG_RUNTIME_DIR'];
  if (xdg != null && xdg.isNotEmpty) {
    paths.add('$xdg/rift-daemon/v0.1.sock');
  }

  final tmpdir = env['TMPDIR'];
  if (tmpdir != null && tmpdir.isNotEmpty) {
    // TMPDIR often ends with '/', but double slashes are fine for unix paths.
    paths.add('$tmpdir/rift-daemon/v0.1.sock');
  }

  final uid = uidOverride ?? _resolveUid();
  if (uid != null && uid.isNotEmpty) {
    paths.add('/tmp/rift-daemon-$uid/v0.1.sock');
  }

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
    final result = Process.runSync('id', const ['-u']);
    if (result.exitCode == 0) {
      final stdout = result.stdout?.toString().trim();
      if (stdout != null && stdout.isNotEmpty) {
        return stdout;
      }
    }
  } catch (_) {
    // Fall through to Linux /proc probing.
  }
  try {
    final statusFile = File('/proc/self/status');
    if (!statusFile.existsSync()) {
      return null;
    }
    for (final line in statusFile.readAsLinesSync()) {
      if (!line.startsWith('Uid:')) continue;
      final parts =
          line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.length >= 2) {
        return parts[1];
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}
