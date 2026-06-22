import 'dart:async';
import 'dart:ffi' as dffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:stream_channel/stream_channel.dart';
import 'package:win32/win32.dart';

import 'ipc_transport.dart';
import 'streamjsonrpc_framer.dart';

class NamedPipeTransport implements IpcTransport {
  final String pipeName;

  Isolate? _worker;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;

  StreamController<List<int>>? _inBytes;
  StreamController<List<int>>? _outBytes;

  // Must match daemon-cs: Rift.Daemon.Windows/WindowsIpcListener.cs (PipeName).
  NamedPipeTransport({this.pipeName = r'\\.\pipe\rift-daemon-v0.1'});

  @override
  Future<StreamChannel<String>> connect() async {
    if (_toWorker != null && _inBytes != null && _outBytes != null) {
      return streamJsonRpcFramer(_inBytes!.stream, _outBytes!.sink);
    }

    _inBytes = StreamController<List<int>>();
    _outBytes = StreamController<List<int>>();
    _fromWorker = ReceivePort();

    final ready = Completer<SendPort>();
    late final StreamSubscription sub;
    sub = _fromWorker!.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is List<int>) {
        _inBytes?.add(msg);
        return;
      }
      if (msg is Map && msg['type'] == 'error') {
        _inBytes?.addError(StateError(msg['message']?.toString() ?? 'pipe worker error'));
        return;
      }
    });

    _worker = await Isolate.spawn(
      _namedPipeWorkerMain,
      <String, dynamic>{
        'pipeName': pipeName,
        'sendPort': _fromWorker!.sendPort,
      },
      errorsAreFatal: true,
    );

    _toWorker = await ready.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Timed out waiting for pipe worker'),
    );

    // Outgoing bytes -> worker.
    _outBytes!.stream.listen((bytes) {
      _toWorker?.send(Uint8List.fromList(bytes));
    }, onDone: () {
      _toWorker?.send({'type': 'close'});
    });

    await sub.cancel();

    return streamJsonRpcFramer(_inBytes!.stream, _outBytes!.sink);
  }

  @override
  Future<void> disconnect() async {
    _toWorker?.send({'type': 'close'});
    _toWorker = null;

    _fromWorker?.close();
    _fromWorker = null;

    await _inBytes?.close();
    await _outBytes?.close();
    _inBytes = null;
    _outBytes = null;

    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
  }
}

void _namedPipeWorkerMain(Map<String, dynamic> args) {
  // Kept in a separate isolate because Win32 ReadFile/WriteFile are blocking.
  // We poll for readability using PeekNamedPipe to avoid needing overlapped IO.
  final pipeName = args['pipeName'] as String;
  final SendPort toUi = args['sendPort'] as SendPort;

  final fromUi = ReceivePort();
  toUi.send(fromUi.sendPort);

  final win32 = _Win32Bindings();

  final handle = win32.openClientPipe(pipeName);
  if (handle == 0) {
    toUi.send({
      'type': 'error',
      'message': 'CreateFile failed for $pipeName (err=${win32.getLastError()})',
    });
    fromUi.close();
    return;
  }

  final outgoing = <Uint8List>[];
  var closed = false;

  fromUi.listen((msg) {
    if (msg is Uint8List) {
      outgoing.add(msg);
      return;
    }
    if (msg is Map && msg['type'] == 'close') {
      closed = true;
    }
  });

  void tick(Timer timer) {
    if (closed) {
      timer.cancel();
      win32.closeHandle(handle);
      fromUi.close();
      return;
    }

    // Flush outgoing queue first.
    while (outgoing.isNotEmpty) {
      final data = outgoing.removeAt(0);
      final ok = win32.writeAll(handle, data);
      if (!ok) {
        toUi.send({
          'type': 'error',
          'message': 'WriteFile failed (err=${win32.getLastError()})',
        });
        closed = true;
        return;
      }
    }

    // Read available bytes.
    final available = win32.peekAvailable(handle);
    if (available <= 0) return;
    final maxRead = available.clamp(1, 4096).toInt();
    final chunk = win32.readSome(handle, maxRead);
    if (chunk == null) {
      toUi.send({
        'type': 'error',
        'message': 'ReadFile failed (err=${win32.getLastError()})',
      });
      closed = true;
      return;
    }
    if (chunk.isNotEmpty) {
      toUi.send(chunk);
    }
  }

  Timer.periodic(const Duration(milliseconds: 5), tick);
}

// Minimal Win32 wrapper to avoid pulling win32 types into the UI isolate.
class _Win32Bindings {
  int getLastError() => GetLastError();

  int openClientPipe(String name) {
    final namePtr = TEXT(name);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final handle = CreateFile(
        namePtr,
        GENERIC_READ | GENERIC_WRITE,
        0,
        dffi.nullptr,
        OPEN_EXISTING,
        0,
        0,
      );
      if (handle != INVALID_HANDLE_VALUE) return handle;

      final err = GetLastError();
      // Common values while the server is starting up.
      if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PIPE_BUSY) {
        if (DateTime.now().isAfter(deadline)) return 0;
        Sleep(50);
        continue;
      }
      return 0;
    }
  }

  bool closeHandle(int handle) => CloseHandle(handle) != 0;

  int peekAvailable(int handle) {
    final availPtr = ffi.calloc<DWORD>();
    try {
      final ok = PeekNamedPipe(handle, dffi.nullptr, 0, dffi.nullptr, availPtr, dffi.nullptr);
      if (ok == 0) return 0;
      return availPtr.value;
    } finally {
      ffi.calloc.free(availPtr);
    }
  }

  Uint8List? readSome(int handle, int maxBytes) {
    final bufPtr = ffi.calloc<dffi.Uint8>(maxBytes);
    final readPtr = ffi.calloc<DWORD>();
    try {
      final ok = ReadFile(handle, bufPtr, maxBytes, readPtr, dffi.nullptr);
      if (ok == 0) return null;
      final n = readPtr.value;
      if (n == 0) return Uint8List(0);
      return Uint8List.fromList(bufPtr.asTypedList(n));
    } finally {
      ffi.calloc.free(bufPtr);
      ffi.calloc.free(readPtr);
    }
  }

  bool writeAll(int handle, Uint8List data) {
    var offset = 0;
    while (offset < data.length) {
      final remaining = data.length - offset;
      final writtenPtr = ffi.calloc<DWORD>();
      final bufPtr = ffi.calloc<dffi.Uint8>(remaining);
      try {
        bufPtr.asTypedList(remaining).setAll(0, data.sublist(offset));
        final ok = WriteFile(handle, bufPtr, remaining, writtenPtr, dffi.nullptr);
        if (ok == 0) return false;
        final n = writtenPtr.value;
        if (n == 0) return false;
        offset += n;
      } finally {
        ffi.calloc.free(bufPtr);
        ffi.calloc.free(writtenPtr);
      }
    }
    return true;
  }
}
