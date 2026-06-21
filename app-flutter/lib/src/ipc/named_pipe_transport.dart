import 'dart:async';
import 'dart:io';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';
import 'streamjsonrpc_framer.dart';

class NamedPipeTransport implements IpcTransport {
  final String pipeName;
  RandomAccessFile? _pipeRead;
  RandomAccessFile? _pipeWrite;
  StreamController<List<int>>? _inBytes;
  StreamController<List<int>>? _outBytes;
  Future<void>? _readLoop;

  // Must match daemon-cs: Rift.Daemon.Windows/WindowsIpcListener.cs (PipeName).
  NamedPipeTransport({this.pipeName = r'\\.\pipe\rift-daemon-v0.1'});

  @override
  Future<StreamChannel<String>> connect() async {
    // On Windows, named pipes can be opened as files using the Win32 file APIs
    // behind dart:io. StreamJsonRpc uses Content-Length framing, so we wrap it.
    final file = File(pipeName);
    _pipeRead = await file.open(mode: FileMode.read);
    _pipeWrite = await file.open(mode: FileMode.write);

    _inBytes = StreamController<List<int>>();
    _outBytes = StreamController<List<int>>();

    // Write loop.
    _outBytes!.stream.listen((data) async {
      final p = _pipeWrite;
      if (p == null) return;
      await p.writeFrom(data);
    });

    // Read loop.
    _readLoop = () async {
      final p = _pipeRead!;
      while (true) {
        final chunk = await p.read(4096);
        if (chunk.isEmpty) break;
        _inBytes?.add(chunk);
      }
    }();
    _readLoop!.catchError((e, st) {
      _inBytes?.addError(e, st);
    }).whenComplete(() {
      _inBytes?.close();
    });

    return streamJsonRpcFramer(_inBytes!.stream, _outBytes!.sink);

  }

  @override
  Future<void> disconnect() async {
    await _inBytes?.close();
    await _outBytes?.close();
    _inBytes = null;
    _outBytes = null;
    await _pipeRead?.close();
    await _pipeWrite?.close();
    _pipeRead = null;
    _pipeWrite = null;
  }
}
