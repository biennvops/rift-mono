import 'dart:io';

import 'package:flutter/services.dart';

class AndroidTlsConnection {
  const AndroidTlsConnection({
    required this.connectionId,
    required this.peerCertificateBase64,
    required this.remoteAddress,
    required this.remotePort,
  });

  final int connectionId;
  final String peerCertificateBase64;
  final String remoteAddress;
  final int remotePort;

  factory AndroidTlsConnection.fromMap(Map<dynamic, dynamic> map) {
    final connectionId = map['connectionId'];
    final certificate = map['peerCertificateBase64'];
    final remoteAddress = map['remoteAddress'];
    final remotePort = map['remotePort'];
    if (connectionId is! int ||
        certificate is! String ||
        remoteAddress is! String ||
        remotePort is! int) {
      throw const FormatException('Invalid native TLS connection response.');
    }
    return AndroidTlsConnection(
      connectionId: connectionId,
      peerCertificateBase64: certificate,
      remoteAddress: remoteAddress,
      remotePort: remotePort,
    );
  }
}

class AndroidNativeTls {
  static const MethodChannel _channel = MethodChannel('rift/android/tls');

  static bool get isSupported => Platform.isAndroid;

  static Future<int> startServer({
    required String certificatePem,
    required String privateKeyPem,
    int port = 0,
  }) async {
    final result = await _channel.invokeMethod<Object>('startServer', {
      'certificatePem': certificatePem,
      'privateKeyPem': privateKeyPem,
      'port': port,
    });
    if (result is! Map || result['port'] is! int) {
      throw const FormatException('Invalid native TLS server response.');
    }
    return result['port'] as int;
  }

  static Future<AndroidTlsConnection> accept() async {
    final result = await _channel.invokeMethod<Object>('accept');
    if (result is! Map) {
      throw const FormatException('Invalid native TLS accept response.');
    }
    return AndroidTlsConnection.fromMap(result);
  }

  static Future<AndroidTlsConnection> connect({
    required String host,
    required int port,
    required String certificatePem,
    required String privateKeyPem,
  }) async {
    final result = await _channel.invokeMethod<Object>('connect', {
      'host': host,
      'port': port,
      'certificatePem': certificatePem,
      'privateKeyPem': privateKeyPem,
    });
    if (result is! Map) {
      throw const FormatException('Invalid native TLS connect response.');
    }
    return AndroidTlsConnection.fromMap(result);
  }

  static Future<Map<String, dynamic>> read(int connectionId) async {
    final result = await _channel.invokeMethod<Object>('read', {
      'connectionId': connectionId,
    });
    if (result is! Map) {
      throw const FormatException('Invalid native TLS read response.');
    }
    return Map<String, dynamic>.from(result);
  }

  static Future<void> write(int connectionId, String dataBase64) async {
    await _channel.invokeMethod<void>('write', {
      'connectionId': connectionId,
      'dataBase64': dataBase64,
    });
  }

  static Future<void> close(int connectionId) async {
    await _channel.invokeMethod<void>('close', {
      'connectionId': connectionId,
    });
  }

  static Future<void> stopServer() async {
    await _channel.invokeMethod<void>('stopServer');
  }
}
