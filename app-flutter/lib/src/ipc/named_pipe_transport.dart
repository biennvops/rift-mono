import 'dart:async';
import 'dart:io';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';

class NamedPipeTransport implements IpcTransport {
  final String pipeName;
  Socket? _socket;

  NamedPipeTransport({this.pipeName = r'\\.\pipe\RiftDaemonPipe'});

  @override
  Future<StreamChannel<String>> connect() async {
    // Windows Named Pipe using InternetAddressType.unix
    // Socket.connect with unix type does not support \\.\pipe paths.
    throw UnimplementedError('Windows Named Pipes require FFI or a dedicated package. Socket.connect(unix) does not support \\\\.\\pipe paths.');

  }

  @override
  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
  }
}
