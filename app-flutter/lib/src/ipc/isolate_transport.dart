import 'dart:async';
import 'dart:isolate';
import 'package:stream_channel/isolate_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';

// Skeleton for future implementation
class IsolateTransport implements IpcTransport {
  final SendPort daemonSendPort;
  ReceivePort? _receivePort;

  IsolateTransport({required this.daemonSendPort});

  @override
  Future<StreamChannel<String>> connect() async {
    _receivePort = ReceivePort();

    // We send our ReceivePort's SendPort to the daemon so it can reply
    daemonSendPort.send(_receivePort!.sendPort);

    // Use IsolateChannel to bridge the ports. Since it handles dynamic types,
    // we map it to String for JSON-RPC compat.
    final channel = IsolateChannel.connectReceive(_receivePort!);
    return channel.cast<String>();
  }

  @override
  Future<void> disconnect() async {
    _receivePort?.close();
    _receivePort = null;
  }
}
