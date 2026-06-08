import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';
import 'bounded_line_splitter.dart';

class NamedPipeTransport implements IpcTransport {
  final String pipeName;
  Socket? _socket;

  NamedPipeTransport({this.pipeName = r'\\.\pipe\RiftDaemonPipe'});

  @override
  Future<StreamChannel<String>> connect() async {
    // Windows Named Pipe using InternetAddressType.unix
    _socket = await Socket.connect(
      InternetAddress(pipeName, type: InternetAddressType.unix),
      0,
    );

    final stream = _socket!
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const BoundedLineSplitter());

    final controller = StreamController<String>();
    controller.stream.map((s) => '$s\n').transform(utf8.encoder).listen((data) {
      _socket?.add(data);
    }, onDone: () {
      _socket?.close();
    }, onError: (e) {
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
