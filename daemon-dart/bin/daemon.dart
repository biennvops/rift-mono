import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daemon_dart/daemon_dart.dart';
import 'package:path/path.dart' as p;
import 'package:daemon_dart/src/core/rift_exceptions.dart';

Future<void> main(List<String> args) async {
  final socketPath = _resolveSocketPath();
  final storagePath = _resolveStoragePath();

  await Directory(storagePath).create(recursive: true);
  final socketFile = await _prepareSocketPath(socketPath);

  final daemon = RiftDaemon(
    storagePath: storagePath,
    enableDiscovery: false,
    enableTransport: true,
  );
  await daemon.start();

  final server = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );

  stdout.writeln('Rift Dart Daemon listening on unix://$socketPath');
  stdout.writeln('Storage path: $storagePath');

  ProcessSignal.sigint.watch().listen((_) async {
    await _shutdown(server, daemon, socketFile);
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    await _shutdown(server, daemon, socketFile);
    exit(0);
  });

  await for (final client in server) {
    unawaited(_handleClient(client, daemon));
  }
}

Future<void> _handleClient(Socket client, RiftDaemon daemon) async {
  final buffer = <int>[];
  int? contentLength;
  const maxContentLength = 1024 * 1024; // 1 MiB

  try {
    await for (final chunk in client) {
      buffer.addAll(chunk);

      while (true) {
        if (contentLength == null) {
          final headerEnd = _indexOfHeaderEnd(buffer);
          if (headerEnd == -1) break;

          final headerText = ascii.decode(buffer.sublist(0, headerEnd));
          final len = _parseContentLength(headerText);
          if (len == null) {
            client.add(_encodeError(null, -32600, 'Missing or invalid Content-Length header'));
            buffer.clear();
            break;
          }
          if (len < 0 || len > maxContentLength) {
            client.add(_encodeError(null, -32600, 'Content-Length out of range'));
            buffer.clear();
            break;
          }

          buffer.removeRange(0, headerEnd + 4);
          contentLength = len;
        }

        final expectedLength = contentLength;
        if (buffer.length < expectedLength) {
          break;
        }

        final body = utf8.decode(buffer.sublist(0, expectedLength));
        buffer.removeRange(0, expectedLength);
        contentLength = null;

        await _processMessage(body, client, daemon);
      }
    }
  } finally {
    await client.close();
  }
}

Future<void> _processMessage(String body, Socket client, RiftDaemon daemon) async {
  Object? id;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      client.add(_encodeError(null, -32600, 'Invalid Request'));
      return;
    }

    final request = Map<String, dynamic>.from(decoded);
    id = request['id'];
    final result = await daemon.handleJsonRpcRequest(request);
    client.add(_encodeJson(RiftDaemon.jsonRpcResult(id, result)));

    if (request['method'] == 'rift.stop') {
      await client.flush();
      await client.close();
    }
  } on RiftException catch (e) {
    client.add(_encodeError(id, e.code, e.message));
  } on UnsupportedError catch (e) {
    client.add(_encodeError(id, -32601, e.toString()));
  } on ArgumentError catch (e) {
    client.add(_encodeError(id, -32602, e.message?.toString() ?? e.toString()));
  } catch (e) {
    client.add(_encodeError(id, -32603, e.toString()));
  }
}

Future<void> _shutdown(ServerSocket server, RiftDaemon daemon, File socketFile) async {
  await server.close();
  await daemon.stop();
  if (await socketFile.exists()) {
    await socketFile.delete();
  }
}

Future<File> _prepareSocketPath(String socketPath) async {
  final socketDir = Directory(p.dirname(socketPath));
  await socketDir.create(recursive: true);
  await _tightenSocketDirectoryPermissions(socketDir);

  final socketFile = File(socketPath);
  if (!await socketFile.exists()) {
    return socketFile;
  }

  try {
    final probe = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      timeout: const Duration(milliseconds: 300),
    );
    await probe.close();
    throw StateError('Another Rift daemon is already listening on unix://$socketPath');
  } on SocketException {
    await socketFile.delete();
    return socketFile;
  } on TimeoutException {
    await socketFile.delete();
    return socketFile;
  }
}

Future<void> _tightenSocketDirectoryPermissions(Directory socketDir) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return;
  }
  try {
    await Process.run('chmod', ['700', socketDir.path]);
  } catch (_) {
    // Best-effort hardening only; local smoke tests should still run even if
    // chmod is unavailable in the host environment.
  }
}

List<int> _encodeJson(Map<String, dynamic> payload) {
  final body = utf8.encode(jsonEncode(payload));
  final header = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
  return <int>[...header, ...body];
}

List<int> _encodeError(Object? id, int code, String message) {
  return _encodeJson(RiftDaemon.jsonRpcError(id, code, message));
}

int _indexOfHeaderEnd(List<int> data) {
  for (var i = 0; i + 3 < data.length; i++) {
    if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

int? _parseContentLength(String headerText) {
  for (final line in headerText.split('\r\n')) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final name = line.substring(0, idx).trim().toLowerCase();
    if (name != 'content-length') continue;
    return int.tryParse(line.substring(idx + 1).trim());
  }
  return null;
}

String _resolveSocketPath() {
  final env = Platform.environment;
  final xdg = env['XDG_RUNTIME_DIR'];
  if (xdg != null && xdg.isNotEmpty) {
    return '$xdg/rift-daemon/v0.1.sock';
  }
  final uid = _resolveUid();
  if (uid != null && uid.isNotEmpty) {
    return '/tmp/rift-daemon-$uid/v0.1.sock';
  }
  return '/tmp/rift-daemon.sock';
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

String _resolveStoragePath() {
  final env = Platform.environment;
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return p.join(xdg, 'rift-daemon');
  }
  final home = env['HOME'];
  if (home != null && home.isNotEmpty) {
    return p.join(home, '.local', 'share', 'rift-daemon');
  }
  return p.join(Directory.systemTemp.path, 'rift-daemon-data');
}
