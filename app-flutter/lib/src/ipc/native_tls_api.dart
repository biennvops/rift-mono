import 'dart:async';
import 'dart:isolate';

import '../platform/android_native_tls.dart';

/// Transport-facing view of the native TLS bridge. The daemon isolate talks
/// to this interface; implementations decide whether the platform channel is
/// invoked directly or proxied through the root isolate.
abstract class NativeTlsApi {
  Future<int> startServer({
    required String certificatePem,
    required String privateKeyPem,
    int port = 0,
  });
  Future<AndroidTlsConnection> accept();
  Future<AndroidTlsConnection> connect({
    required String host,
    required int port,
    required String certificatePem,
    required String privateKeyPem,
  });
  Future<Map<String, dynamic>> read(int connectionId);
  Future<void> write(int connectionId, String dataBase64);
  Future<void> close(int connectionId);
  Future<void> stopServer();
}

/// Direct method-channel implementation. Safe only on isolates that live as
/// long as the Flutter engine (the root isolate on iOS).
class MethodChannelNativeTlsApi implements NativeTlsApi {
  @override
  Future<int> startServer({
    required String certificatePem,
    required String privateKeyPem,
    int port = 0,
  }) =>
      AndroidNativeTls.startServer(
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
        port: port,
      );

  @override
  Future<AndroidTlsConnection> accept() => AndroidNativeTls.accept();

  @override
  Future<AndroidTlsConnection> connect({
    required String host,
    required int port,
    required String certificatePem,
    required String privateKeyPem,
  }) =>
      AndroidNativeTls.connect(
        host: host,
        port: port,
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
      );

  @override
  Future<Map<String, dynamic>> read(int connectionId) =>
      AndroidNativeTls.read(connectionId);

  @override
  Future<void> write(int connectionId, String dataBase64) =>
      AndroidNativeTls.write(connectionId, dataBase64);

  @override
  Future<void> close(int connectionId) => AndroidNativeTls.close(connectionId);

  @override
  Future<void> stopServer() => AndroidNativeTls.stopServer();
}

/// Root-isolate host that executes TLS platform-channel calls on behalf of
/// the Android daemon isolate. Platform replies always target the root
/// isolate, which outlives daemon restarts; results are relayed to the daemon
/// isolate over SendPort, where sends to a dead isolate are silently dropped
/// instead of aborting the engine (`Check failed: did_send`).
class NativeTlsProxyHost {
  final ReceivePort _requests = ReceivePort();
  StreamSubscription<dynamic>? _subscription;
  final NativeTlsApi _api = MethodChannelNativeTlsApi();

  SendPort get requestPort => _requests.sendPort;

  void start() {
    _subscription ??= _requests.listen(_handleRequest);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _requests.close();
    try {
      await _api.stopServer();
    } catch (_) {}
  }

  void _handleRequest(dynamic message) {
    if (message is! Map) return;
    final id = message['id'];
    final method = message['method'];
    final replyTo = message['replyTo'];
    if (method is! String || replyTo is! SendPort) return;
    final args = message['args'] is Map
        ? Map<String, dynamic>.from(message['args'] as Map)
        : const <String, dynamic>{};

    unawaited(() async {
      try {
        final value = await _invoke(method, args);
        replyTo.send({'id': id, 'ok': true, 'value': value});
      } catch (error) {
        replyTo.send({'id': id, 'ok': false, 'error': error.toString()});
      }
    }());
  }

  Future<Object?> _invoke(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'startServer':
        return _api.startServer(
          certificatePem: args['certificatePem'] as String,
          privateKeyPem: args['privateKeyPem'] as String,
          port: args['port'] as int? ?? 0,
        );
      case 'accept':
        return _connectionToMap(await _api.accept());
      case 'connect':
        return _connectionToMap(await _api.connect(
          host: args['host'] as String,
          port: args['port'] as int,
          certificatePem: args['certificatePem'] as String,
          privateKeyPem: args['privateKeyPem'] as String,
        ));
      case 'read':
        return _api.read(args['connectionId'] as int);
      case 'write':
        await _api.write(
          args['connectionId'] as int,
          args['dataBase64'] as String,
        );
        return null;
      case 'close':
        await _api.close(args['connectionId'] as int);
        return null;
      case 'stopServer':
        await _api.stopServer();
        return null;
      default:
        throw UnsupportedError('Unknown native TLS method: $method');
    }
  }

  static Map<String, Object?> _connectionToMap(AndroidTlsConnection c) => {
        'connectionId': c.connectionId,
        'peerCertificateBase64': c.peerCertificateBase64,
        'remoteAddress': c.remoteAddress,
        'remotePort': c.remotePort,
      };
}

/// Daemon-isolate client that forwards TLS calls to a [NativeTlsProxyHost]
/// running on the root isolate.
class SendPortNativeTlsApi implements NativeTlsApi {
  SendPortNativeTlsApi(this._host) {
    _replies.listen(_handleReply);
  }

  final SendPort _host;
  final ReceivePort _replies = ReceivePort();
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 1;

  void _handleReply(dynamic message) {
    if (message is! Map) return;
    final completer = _pending.remove(message['id']);
    if (completer == null) return;
    if (message['ok'] == true) {
      completer.complete(message['value']);
    } else {
      completer.completeError(
        StateError(message['error']?.toString() ?? 'Native TLS call failed'),
      );
    }
  }

  Future<Object?> _call(String method, [Map<String, Object?>? args]) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _host.send({
      'id': id,
      'method': method,
      if (args != null) 'args': args,
      'replyTo': _replies.sendPort,
    });
    return completer.future;
  }

  @override
  Future<int> startServer({
    required String certificatePem,
    required String privateKeyPem,
    int port = 0,
  }) async {
    final value = await _call('startServer', {
      'certificatePem': certificatePem,
      'privateKeyPem': privateKeyPem,
      'port': port,
    });
    return value as int;
  }

  @override
  Future<AndroidTlsConnection> accept() async {
    final value = await _call('accept');
    return AndroidTlsConnection.fromMap(value as Map);
  }

  @override
  Future<AndroidTlsConnection> connect({
    required String host,
    required int port,
    required String certificatePem,
    required String privateKeyPem,
  }) async {
    final value = await _call('connect', {
      'host': host,
      'port': port,
      'certificatePem': certificatePem,
      'privateKeyPem': privateKeyPem,
    });
    return AndroidTlsConnection.fromMap(value as Map);
  }

  @override
  Future<Map<String, dynamic>> read(int connectionId) async {
    final value = await _call('read', {'connectionId': connectionId});
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<void> write(int connectionId, String dataBase64) => _call('write', {
        'connectionId': connectionId,
        'dataBase64': dataBase64,
      });

  @override
  Future<void> close(int connectionId) =>
      _call('close', {'connectionId': connectionId});

  @override
  Future<void> stopServer() => _call('stopServer');
}
