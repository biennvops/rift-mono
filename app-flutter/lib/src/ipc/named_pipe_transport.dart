import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as dffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:win32/win32.dart';

import 'ipc_transport.dart';
import 'streamjsonrpc_framer.dart';

const _controlReady = 'controlReady';
const _pipeConnected = 'pipeConnected';
const _data = 'data';
const _fatal = 'fatal';
const _stopped = 'stopped';
const _close = 'close';

class NamedPipeTransport implements IpcTransport {
  final String pipeName;
  final Duration connectTimeout;
  final Duration shutdownTimeout;
  final NamedPipeWorkerSpawner _spawner;
  final _log = Logger('NamedPipeTransport');

  int _generation = 0;
  _PipeConnection? _active;
  _PipeConnection? _pending;
  Future<StreamChannel<String>>? _connecting;
  Future<void>? _disconnecting;

  NamedPipeTransport({
    this.pipeName = r'\\.\pipe\rift-daemon-v0.1',
    this.connectTimeout = const Duration(seconds: 6),
    this.shutdownTimeout = const Duration(seconds: 1),
    NamedPipeWorkerSpawner workerSpawner =
        const IsolateNamedPipeWorkerSpawner(),
  }) : _spawner = workerSpawner;

  @override
  Future<StreamChannel<String>> connect() async {
    if (_disconnecting != null) await _disconnecting;
    if (_active case final active? when !active.isTerminal) {
      return active.channel;
    }
    if (_connecting case final connecting?) return connecting;

    final attempt = _PipeConnection(
      generation: ++_generation,
      pipeName: pipeName,
      spawner: _spawner,
      shutdownTimeout: shutdownTimeout,
      log: _log,
      onTerminal: _onTerminal,
    );
    _pending = attempt;
    late final Future<StreamChannel<String>> future;
    future = _start(attempt).whenComplete(() {
      if (identical(_connecting, future)) _connecting = null;
      if (identical(_pending, attempt)) _pending = null;
    });
    _connecting = future;
    return future;
  }

  Future<StreamChannel<String>> _start(_PipeConnection attempt) async {
    try {
      _log.fine(
          'Windows pipe worker generation=${attempt.generation} starting');
      await attempt.start().timeout(
            connectTimeout,
            onTimeout: () => throw TimeoutException(
              'Timed out connecting to $pipeName',
              connectTimeout,
            ),
          );
      if (_generation != attempt.generation || !identical(_pending, attempt)) {
        throw StateError('Pipe connection generation was invalidated');
      }
      _active = attempt;
      _log.info('Windows pipe generation=${attempt.generation} connected');
      return attempt.channel;
    } catch (_) {
      await attempt.shutdown();
      rethrow;
    }
  }

  void _onTerminal(_PipeConnection connection, Object error) {
    if (!identical(_active, connection) && !identical(_pending, connection)) {
      _log.fine(
          'Windows pipe stale event ignored generation=${connection.generation}');
      return;
    }
    if (identical(_active, connection)) _active = null;
    if (identical(_pending, connection)) _pending = null;
    _generation++;
    _beginDisconnect(connection, workerIsStopping: true);
  }

  @override
  Future<void> disconnect() {
    if (_disconnecting case final disconnecting?) return disconnecting;
    _generation++;
    final owned = _active ?? _pending;
    _active = null;
    _pending = null;
    return _beginDisconnect(owned);
  }

  Future<void> _beginDisconnect(
    _PipeConnection? connection, {
    bool workerIsStopping = false,
  }) {
    late final Future<void> result;
    result = (connection?.shutdown(workerIsStopping: workerIsStopping) ??
            Future<void>.value())
        .whenComplete(() {
      if (identical(_disconnecting, result)) _disconnecting = null;
    });
    _disconnecting = result;
    return result;
  }
}

abstract interface class NamedPipeWorkerSpawner {
  Future<NamedPipeWorkerProcess> spawn(String pipeName, int generation);
}

abstract interface class NamedPipeWorkerProcess {
  Stream<Object?> get events;
  Stream<Object?> get errors;
  Stream<Object?> get exits;
  void send(Object message);
  void kill();
  void close();
}

class IsolateNamedPipeWorkerSpawner implements NamedPipeWorkerSpawner {
  const IsolateNamedPipeWorkerSpawner();

  @override
  Future<NamedPipeWorkerProcess> spawn(String pipeName, int generation) async {
    final events = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    try {
      final isolate = await Isolate.spawn(
        _namedPipeWorkerMain,
        {
          'pipeName': pipeName,
          'generation': generation,
          'sendPort': events.sendPort
        },
        errorsAreFatal: true,
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
      return _IsolateWorker(isolate, events, errors, exits);
    } catch (_) {
      events.close();
      errors.close();
      exits.close();
      rethrow;
    }
  }
}

class _IsolateWorker implements NamedPipeWorkerProcess {
  final Isolate isolate;
  final ReceivePort eventPort;
  final ReceivePort errorPort;
  final ReceivePort exitPort;
  SendPort? controlPort;

  _IsolateWorker(this.isolate, this.eventPort, this.errorPort, this.exitPort);

  @override
  Stream<Object?> get events => eventPort;
  @override
  Stream<Object?> get errors => errorPort;
  @override
  Stream<Object?> get exits => exitPort;
  @override
  void send(Object message) => controlPort?.send(message);
  @override
  void kill() => isolate.kill(priority: Isolate.immediate);
  @override
  void close() {
    eventPort.close();
    errorPort.close();
    exitPort.close();
  }
}

class _PipeConnection {
  final int generation;
  final String pipeName;
  final NamedPipeWorkerSpawner spawner;
  final Duration shutdownTimeout;
  final Logger log;
  final void Function(_PipeConnection, Object) onTerminal;
  final incoming = StreamController<List<int>>();
  final outgoing = StreamController<List<int>>();
  final connected = Completer<void>();
  final stopped = Completer<void>();
  final exited = Completer<void>();

  NamedPipeWorkerProcess? worker;
  StreamSubscription<Object?>? eventSubscription;
  StreamSubscription<Object?>? errorSubscription;
  StreamSubscription<Object?>? exitSubscription;
  StreamSubscription<List<int>>? outgoingSubscription;
  Future<void>? shutdownFuture;
  bool controlReady = false;
  bool committed = false;
  bool expectedStop = false;
  bool isTerminal = false;
  bool closed = false;

  _PipeConnection({
    required this.generation,
    required this.pipeName,
    required this.spawner,
    required this.shutdownTimeout,
    required this.log,
    required this.onTerminal,
  });

  StreamChannel<String> get channel =>
      streamJsonRpcFramer(incoming.stream, outgoing.sink);

  Future<void> start() async {
    final process = await spawner.spawn(pipeName, generation);
    if (shutdownFuture != null) {
      process.kill();
      process.close();
      throw StateError('Pipe connection generation=$generation was cancelled');
    }
    worker = process;
    eventSubscription = process.events.listen(_handleEvent);
    errorSubscription = process.errors.listen((error) {
      _fail(StateError('Pipe worker exception generation=$generation: $error'));
    });
    exitSubscription = process.exits.listen((_) {
      if (!exited.isCompleted) exited.complete();
      if (!expectedStop && !isTerminal) {
        _fail(StateError(
            'Pipe worker exited unexpectedly generation=$generation'));
      }
    });
    outgoingSubscription = outgoing.stream.listen(
      (bytes) => process.send(Uint8List.fromList(bytes)),
      onDone: () => process.send(const {'type': _close}),
    );
    await connected.future;
    committed = true;
  }

  void _handleEvent(Object? message) {
    if (closed || message is! Map) return;
    switch (message['type']) {
      case _controlReady:
        final port = message['port'];
        if (port is! SendPort) {
          return _fail(StateError('Invalid worker control port'));
        }
        if (worker case final _IsolateWorker isolateWorker) {
          isolateWorker.controlPort = port;
        }
        controlReady = true;
        log.fine('Windows pipe worker generation=$generation control ready');
      case _pipeConnected:
        if (!controlReady) {
          return _fail(StateError('Pipe connected before control ready'));
        }
        if (!connected.isCompleted) connected.complete();
      case _data:
        final bytes = message['bytes'];
        if (!committed) {
          return _fail(
              StateError('Pipe data arrived before connection commit'));
        }
        if (bytes is List<int> && !incoming.isClosed) incoming.add(bytes);
      case _fatal:
        final operation = message['operation'] ?? 'worker';
        _fail(StateError(
          '${message['message'] ?? 'Named-pipe $operation failed'} for $pipeName '
          'generation=$generation error=${message['errorCode']}',
        ));
      case _stopped:
        if (!stopped.isCompleted) stopped.complete();
      default:
        _fail(StateError('Unknown pipe worker message: ${message['type']}'));
    }
  }

  void _fail(Object error) {
    if (isTerminal) return;
    isTerminal = true;
    if (!connected.isCompleted) {
      connected.completeError(error);
    } else if (!incoming.isClosed) {
      incoming.addError(error);
      unawaited(incoming.close());
    }
    onTerminal(this, error);
  }

  Future<void> shutdown({bool workerIsStopping = false}) {
    if (shutdownFuture case final existing?) return existing;
    expectedStop = true;
    if (!connected.isCompleted) {
      connected.completeError(
          StateError('Pipe connection generation=$generation was cancelled'));
    }
    return shutdownFuture = _shutdown(workerIsStopping);
  }

  Future<void> _shutdown(bool workerIsStopping) async {
    final process = worker;
    if (process != null) {
      if (!workerIsStopping) {
        log.fine('Windows pipe worker stopping generation=$generation');
        process.send(const {'type': _close});
        try {
          await stopped.future.timeout(shutdownTimeout);
        } on TimeoutException {
          log.warning('Windows pipe shutdown timed out generation=$generation');
          process.kill();
        }
      } else {
        // Terminal notifications run inside the worker event subscription.
        // Defer cancellation until that callback has returned.
        await Future<void>.value();
      }
    }
    if (closed) return;
    closed = true;
    await eventSubscription?.cancel();
    await errorSubscription?.cancel();
    await exitSubscription?.cancel();
    await outgoingSubscription?.cancel();
    process?.close();
    if (!incoming.isClosed) unawaited(incoming.close());
    if (!outgoing.isClosed) unawaited(outgoing.close());
    log.fine('Windows pipe worker stopped generation=$generation');
  }
}

void _namedPipeWorkerMain(Map<String, dynamic> args) {
  final toParent = args['sendPort'] as SendPort;
  final commands = ReceivePort();
  final io = Win32NamedPipeIo();
  late final StreamSubscription<Object?> subscription;
  late final NamedPipeWorkerSession session;
  session = NamedPipeWorkerSession(
    pipeName: args['pipeName'] as String,
    generation: args['generation'] as int,
    io: io,
    send: toParent.send,
    onFinished: () {
      unawaited(subscription.cancel());
      commands.close();
      io.dispose();
    },
  );
  subscription = commands.listen(session.handleCommand);
  toParent.send({'type': _controlReady, 'port': commands.sendPort});
  session.start();
}

class PipeOpenResult {
  final int? handle;
  final int errorCode;
  const PipeOpenResult.success(int this.handle) : errorCode = ERROR_SUCCESS;
  const PipeOpenResult.failure(this.errorCode) : handle = null;
}

class PipePeekResult {
  final bool success;
  final int available;
  final int? errorCode;
  const PipePeekResult.success(this.available)
      : success = true,
        errorCode = null;
  const PipePeekResult.failure(int this.errorCode)
      : success = false,
        available = 0;
}

class PipeReadResult {
  final Uint8List? bytes;
  final int? errorCode;
  const PipeReadResult.success(Uint8List this.bytes) : errorCode = null;
  const PipeReadResult.failure(int this.errorCode) : bytes = null;
}

class PipeWriteResult {
  final int bytesWritten;
  final int? errorCode;
  const PipeWriteResult.success(this.bytesWritten) : errorCode = null;
  const PipeWriteResult.failure(int this.errorCode) : bytesWritten = 0;
}

abstract interface class NamedPipeWorkerIo {
  PipeOpenResult openClientPipe(String name);
  PipePeekResult peekAvailable(int handle);
  PipeReadResult readSome(int handle, int maxBytes);
  PipeWriteResult writeSome(int handle, Uint8List data, int offset);
  void closeHandle(int handle);
  void dispose();
}

class NamedPipeWorkerSession {
  final String pipeName;
  final int generation;
  final NamedPipeWorkerIo io;
  final void Function(Object?) send;
  final void Function() onFinished;
  final Duration openRetryInterval;
  final Duration openTimeout;
  final Duration pollInterval;
  final outgoing = ListQueue<Uint8List>();
  final openStopwatch = Stopwatch();
  Timer? openTimer;
  Timer? pollTimer;
  int? handle;
  int openAttempts = 0;
  int lastOpenError = ERROR_SUCCESS;
  bool isClosed = false;

  NamedPipeWorkerSession({
    required this.pipeName,
    required this.generation,
    required this.io,
    required this.send,
    required this.onFinished,
    this.openRetryInterval = const Duration(milliseconds: 50),
    this.openTimeout = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 15),
  });

  void start() {
    openStopwatch.start();
    _tryOpen();
  }

  void handleCommand(Object? message) {
    if (isClosed) return;
    if (message is Uint8List) {
      if (handle != null) outgoing.add(message);
    } else if (message is Map && message['type'] == _close) {
      _finish(normal: true);
    }
  }

  void _tryOpen() {
    if (isClosed) return;
    openAttempts++;
    final result = io.openClientPipe(pipeName);
    if (result.handle case final opened?) {
      openStopwatch.stop();
      handle = opened;
      send({'type': _pipeConnected});
      pollTimer = Timer.periodic(pollInterval, (_) => poll());
      return;
    }
    lastOpenError = result.errorCode;
    final retryable = result.errorCode == ERROR_FILE_NOT_FOUND ||
        result.errorCode == ERROR_PIPE_BUSY;
    if (retryable && openStopwatch.elapsed < openTimeout) {
      openTimer = Timer(openRetryInterval, _tryOpen);
    } else {
      _fail('open', result.errorCode,
          'Named-pipe open failed after $openAttempts attempts');
    }
  }

  void poll() {
    if (isClosed || handle == null) return;
    final pipe = handle!;
    while (outgoing.isNotEmpty) {
      final bytes = outgoing.removeFirst();
      var offset = 0;
      while (offset < bytes.length) {
        final result = io.writeSome(pipe, bytes, offset);
        if (result.errorCode != null || result.bytesWritten <= 0) {
          return _fail('write', result.errorCode ?? ERROR_WRITE_FAULT,
              'Named-pipe write failed');
        }
        offset += result.bytesWritten;
      }
    }
    final peek = io.peekAvailable(pipe);
    if (!peek.success) {
      return _fail('peek', peek.errorCode!, 'Named-pipe probe failed');
    }
    if (peek.available == 0) return;
    final result = io.readSome(pipe, peek.available.clamp(1, 4096));
    if (result.bytes == null) {
      return _fail('read', result.errorCode!, 'Named-pipe read failed');
    }
    if (result.bytes!.isNotEmpty) send({'type': _data, 'bytes': result.bytes!});
  }

  void _fail(String operation, int errorCode, String message) {
    if (isClosed) return;
    send({
      'type': _fatal,
      'operation': operation,
      'errorCode': errorCode,
      'message': message,
      if (operation == 'open') 'attempts': openAttempts,
      if (operation == 'open') 'lastError': lastOpenError,
    });
    _finish(normal: false);
  }

  void _finish({required bool normal}) {
    if (isClosed) return;
    isClosed = true;
    openTimer?.cancel();
    pollTimer?.cancel();
    openStopwatch.stop();
    if (handle case final owned?) io.closeHandle(owned);
    handle = null;
    if (normal) send({'type': _stopped});
    onFinished();
  }
}

class Win32NamedPipeIo implements NamedPipeWorkerIo {
  final available = ffi.calloc<DWORD>();
  final transferred = ffi.calloc<DWORD>();
  bool disposed = false;

  @override
  PipeOpenResult openClientPipe(String name) {
    final namePointer = TEXT(name);
    try {
      final handle = CreateFile(namePointer, GENERIC_READ | GENERIC_WRITE, 0,
          dffi.nullptr, OPEN_EXISTING, 0, 0);
      return handle == INVALID_HANDLE_VALUE
          ? PipeOpenResult.failure(GetLastError())
          : PipeOpenResult.success(handle);
    } finally {
      ffi.calloc.free(namePointer);
    }
  }

  @override
  PipePeekResult peekAvailable(int handle) {
    final ok = PeekNamedPipe(
        handle, dffi.nullptr, 0, dffi.nullptr, available, dffi.nullptr);
    return ok == 0
        ? PipePeekResult.failure(GetLastError())
        : PipePeekResult.success(available.value);
  }

  @override
  PipeReadResult readSome(int handle, int maxBytes) {
    final buffer = ffi.calloc<dffi.Uint8>(maxBytes);
    try {
      final ok = ReadFile(handle, buffer, maxBytes, transferred, dffi.nullptr);
      return ok == 0
          ? PipeReadResult.failure(GetLastError())
          : PipeReadResult.success(
              Uint8List.fromList(buffer.asTypedList(transferred.value)));
    } finally {
      ffi.calloc.free(buffer);
    }
  }

  @override
  PipeWriteResult writeSome(int handle, Uint8List data, int offset) {
    final remaining = data.length - offset;
    final buffer = ffi.calloc<dffi.Uint8>(remaining);
    try {
      buffer.asTypedList(remaining).setRange(0, remaining, data, offset);
      final ok =
          WriteFile(handle, buffer, remaining, transferred, dffi.nullptr);
      return ok == 0
          ? PipeWriteResult.failure(GetLastError())
          : PipeWriteResult.success(transferred.value);
    } finally {
      ffi.calloc.free(buffer);
    }
  }

  @override
  void closeHandle(int handle) => CloseHandle(handle);

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    ffi.calloc.free(available);
    ffi.calloc.free(transferred);
  }
}
