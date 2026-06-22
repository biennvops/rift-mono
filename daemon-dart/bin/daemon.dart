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
  final socketFile = File(socketPath);
  if (await socketFile.exists()) {
    await socketFile.delete();
  }
  await Directory(p.dirname(socketPath)).create(recursive: true);

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
  final uid = env['UID'];
  if (uid != null && uid.isNotEmpty) {
    return '/tmp/rift-daemon-$uid/v0.1.sock';
  }
  return '/tmp/rift-daemon.sock';
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
