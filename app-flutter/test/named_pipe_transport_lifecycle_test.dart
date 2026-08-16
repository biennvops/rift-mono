import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/ipc/named_pipe_transport.dart';

void main() {
  group('NamedPipeTransport lifecycle', () {
    test('control ready does not complete connect', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      var completed = false;
      final connect = transport.connect()..then((_) => completed = true);
      await pumpEventQueue();

      spawner.last.controlReady();
      await pumpEventQueue();
      expect(completed, isFalse);

      spawner.last.connected();
      await connect;
      expect(completed, isTrue);
      await _disconnectNormally(transport, spawner.last);
    });

    test('open failure fails connect and cleans worker', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      final connect = transport.connect();
      await pumpEventQueue();
      spawner.last
        ..controlReady()
        ..fatal('open', 2);
      spawner.last.exit();

      await expectLater(connect, throwsStateError);
      expect(spawner.last.closed, isTrue);
      expect(spawner.liveWorkers, 0);
    });

    test('connect timeout rolls back worker', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(
        spawner,
        connectTimeout: Duration.zero,
        shutdownTimeout: Duration.zero,
      );

      await expectLater(transport.connect(), throwsA(isA<TimeoutException>()));
      expect(spawner.last.killed, isTrue);
      expect(spawner.last.closed, isTrue);
    });

    test('worker exit before connection fails promptly', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      final connect = transport.connect();
      await pumpEventQueue();
      spawner.last
        ..controlReady()
        ..exit();

      await expectLater(connect, throwsStateError);
      expect(spawner.last.closed, isTrue);
    });

    test('unexpected exit after connect errors the stream', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      final connect = transport.connect();
      await pumpEventQueue();
      spawner.last
        ..controlReady()
        ..connected();
      final channel = await connect;
      final error = Completer<Object>();
      channel.stream.listen((_) {}, onError: error.complete);

      spawner.last.exit();
      expect(await error.future, isA<StateError>());
      await pumpEventQueue();
      expect(spawner.last.closed, isTrue);
    });

    test('normal disconnect waits for stopped acknowledgement', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      await _connect(transport, spawner);
      var completed = false;
      final disconnect = transport.disconnect()..then((_) => completed = true);
      await pumpEventQueue();

      expect(spawner.last.closeRequests, 1);
      expect(completed, isFalse);
      spawner.last.stopped();
      await disconnect;
      expect(completed, isTrue);
      expect(spawner.last.killed, isFalse);
    });

    test('shutdown timeout kills unresponsive worker', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(
        spawner,
        shutdownTimeout: Duration.zero,
      );
      await _connect(transport, spawner);

      await transport.disconnect();

      expect(spawner.last.killed, isTrue);
      expect(spawner.last.closed, isTrue);
    });

    test('disconnect is idempotent', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      await _connect(transport, spawner);
      final disconnects = [
        transport.disconnect(),
        transport.disconnect(),
        transport.disconnect(),
      ];
      expect(spawner.last.closeRequests, 1);
      spawner.last.stopped();
      await Future.wait(disconnects);
      expect(spawner.last.closeRequests, 1);
    });

    test('concurrent connects share one worker', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      final first = transport.connect();
      final second = transport.connect();
      await pumpEventQueue();
      expect(spawner.spawnCount, 1);
      spawner.last
        ..controlReady()
        ..connected();
      final channels = await Future.wait([first, second]);
      expect(identical(channels.first, channels.last), isTrue);
      await _disconnectNormally(transport, spawner.last);
    });

    test('disconnect during connect cannot resurrect connection', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      final connect = transport.connect();
      final expectation = expectLater(connect, throwsStateError);
      await pumpEventQueue();
      final stale = spawner.last..controlReady();
      final disconnect = transport.disconnect();
      stale.stopped();
      await disconnect;
      stale.connected();
      await expectation;

      final reconnect = transport.connect();
      await pumpEventQueue();
      expect(spawner.spawnCount, 2);
      spawner.last
        ..controlReady()
        ..connected();
      await reconnect;
      await _disconnectNormally(transport, spawner.last);
    });

    test('stale failure cannot kill replacement', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      await _connect(transport, spawner);
      final first = spawner.last;
      final disconnect = transport.disconnect();
      first.stopped();
      await disconnect;
      await _connect(transport, spawner);
      final replacement = spawner.last;

      first
        ..fatal('peek', 109)
        ..exit();
      await pumpEventQueue();
      expect(replacement.closed, isFalse);
      expect(spawner.liveWorkers, 1);
      await _disconnectNormally(transport, replacement);
    });

    test('repeated cycles leave no live workers', () async {
      final spawner = _FakeSpawner();
      final transport = _transport(spawner);
      for (var i = 0; i < 50; i++) {
        await _connect(transport, spawner);
        await _disconnectNormally(transport, spawner.last);
        expect(spawner.liveWorkers, 0);
      }
      expect(spawner.spawnCount, 50);
    });
  });

  group('NamedPipeWorkerSession', () {
    test('failed peek is fatal and closes handle exactly once', () {
      final io = _FakeIo()..peekResults.add(const PipePeekResult.failure(109));
      final harness = _SessionHarness(io)..start();
      harness.session.poll();
      harness.session.poll();

      expect(harness.fatals.single['operation'], 'peek');
      expect(harness.fatals.single['errorCode'], 109);
      expect(io.closeCalls, 1);
      expect(harness.session.isClosed, isTrue);
    });

    test('successful zero-byte peek remains idle', () {
      final io = _FakeIo()..peekResults.add(const PipePeekResult.success(0));
      final harness = _SessionHarness(io)..start();
      harness.session.poll();

      expect(harness.fatals, isEmpty);
      expect(io.readCalls, 0);
      expect(harness.session.isClosed, isFalse);
      harness.close();
    });

    test('read failure is terminal', () {
      final io = _FakeIo()
        ..peekResults.add(const PipePeekResult.success(8))
        ..readResults.add(const PipeReadResult.failure(109));
      final harness = _SessionHarness(io)..start();
      harness.session.poll();

      expect(harness.fatals.single['operation'], 'read');
      expect(io.closeCalls, 1);
    });

    test('write failure is terminal', () {
      final io = _FakeIo()
        ..writeResults.add(const PipeWriteResult.failure(232));
      final harness = _SessionHarness(io)..start();
      harness.session.handleCommand(Uint8List.fromList([1, 2]));
      harness.session.poll();

      expect(harness.fatals.single['operation'], 'write');
      expect(io.closeCalls, 1);
    });

    test('outgoing queue and partial writes preserve order', () {
      final io = _FakeIo()
        ..writeResults.addAll(const [
          PipeWriteResult.success(1),
          PipeWriteResult.success(2),
          PipeWriteResult.success(1),
        ])
        ..peekResults.add(const PipePeekResult.success(0));
      final harness = _SessionHarness(io)..start();
      harness.session
        ..handleCommand(Uint8List.fromList([1, 2, 3]))
        ..handleCommand(Uint8List.fromList([4]))
        ..poll();

      expect(io.writes, [
        [1, 2, 3],
        [2, 3],
        [4],
      ]);
      harness.close();
    });

    test('normal close acknowledges after handle close', () {
      final io = _FakeIo();
      final events = <Map<Object?, Object?>>[];
      final session = NamedPipeWorkerSession(
        pipeName: 'pipe',
        generation: 1,
        io: io,
        send: (event) => events.add(Map<Object?, Object?>.from(event as Map)),
        onFinished: () => events.add({'type': 'finished'}),
      )..start();
      session.handleCommand({'type': 'close'});

      expect(io.closeCalls, 1);
      expect(events.map((event) => event['type']),
          ['pipeConnected', 'stopped', 'finished']);
    });
  });
}

NamedPipeTransport _transport(
  _FakeSpawner spawner, {
  Duration connectTimeout = const Duration(seconds: 5),
  Duration shutdownTimeout = const Duration(milliseconds: 100),
}) =>
    NamedPipeTransport(
      workerSpawner: spawner,
      connectTimeout: connectTimeout,
      shutdownTimeout: shutdownTimeout,
    );

Future<void> _connect(
    NamedPipeTransport transport, _FakeSpawner spawner) async {
  final connect = transport.connect();
  await pumpEventQueue();
  spawner.last
    ..controlReady()
    ..connected();
  await connect;
}

Future<void> _disconnectNormally(
  NamedPipeTransport transport,
  _FakeProcess process,
) async {
  final disconnect = transport.disconnect();
  process.stopped();
  await disconnect;
}

class _FakeSpawner implements NamedPipeWorkerSpawner {
  final processes = <_FakeProcess>[];
  int get spawnCount => processes.length;
  int get liveWorkers => processes.where((process) => !process.closed).length;
  _FakeProcess get last => processes.last;

  @override
  Future<NamedPipeWorkerProcess> spawn(String pipeName, int generation) async {
    final process = _FakeProcess();
    processes.add(process);
    return process;
  }
}

class _FakeProcess implements NamedPipeWorkerProcess {
  final eventController = StreamController<Object?>(sync: true);
  final errorController = StreamController<Object?>(sync: true);
  final exitController = StreamController<Object?>(sync: true);
  final controlToken = ReceivePort();
  int closeRequests = 0;
  bool killed = false;
  bool closed = false;

  @override
  Stream<Object?> get events => eventController.stream;
  @override
  Stream<Object?> get errors => errorController.stream;
  @override
  Stream<Object?> get exits => exitController.stream;

  void controlReady() {
    if (!closed) {
      eventController.add(
        {'type': 'controlReady', 'port': controlToken.sendPort},
      );
    }
  }

  void connected() {
    if (!closed) eventController.add({'type': 'pipeConnected'});
  }

  void fatal(String operation, int code) {
    if (closed) return;
    eventController.add({
      'type': 'fatal',
      'operation': operation,
      'errorCode': code,
      'message': 'failed',
    });
  }

  void stopped() {
    if (!closed) eventController.add({'type': 'stopped'});
  }

  void exit() {
    if (!closed) exitController.add(null);
  }

  @override
  void send(Object message) {
    if (message is Map && message['type'] == 'close') closeRequests++;
  }

  @override
  void kill() => killed = true;

  @override
  void close() {
    if (closed) return;
    closed = true;
    controlToken.close();
    unawaited(eventController.close());
    unawaited(errorController.close());
    unawaited(exitController.close());
  }
}

class _SessionHarness {
  final _FakeIo io;
  final events = <Map<Object?, Object?>>[];
  late final NamedPipeWorkerSession session = NamedPipeWorkerSession(
    pipeName: 'pipe',
    generation: 1,
    io: io,
    send: (event) => events.add(Map<Object?, Object?>.from(event as Map)),
    onFinished: () {},
  );

  _SessionHarness(this.io);
  Iterable<Map<Object?, Object?>> get fatals =>
      events.where((event) => event['type'] == 'fatal');
  void start() => session.start();
  void close() => session.handleCommand({'type': 'close'});
}

class _FakeIo implements NamedPipeWorkerIo {
  final peekResults = <PipePeekResult>[];
  final readResults = <PipeReadResult>[];
  final writeResults = <PipeWriteResult>[];
  final writes = <List<int>>[];
  int readCalls = 0;
  int closeCalls = 0;

  @override
  PipeOpenResult openClientPipe(String name) => const PipeOpenResult.success(7);
  @override
  PipePeekResult peekAvailable(int handle) => peekResults.isEmpty
      ? const PipePeekResult.success(0)
      : peekResults.removeAt(0);
  @override
  PipeReadResult readSome(int handle, int maxBytes) {
    readCalls++;
    return readResults.removeAt(0);
  }

  @override
  PipeWriteResult writeSome(int handle, Uint8List data, int offset) {
    writes.add(data.sublist(offset));
    return writeResults.isEmpty
        ? PipeWriteResult.success(data.length - offset)
        : writeResults.removeAt(0);
  }

  @override
  void closeHandle(int handle) => closeCalls++;
  @override
  void dispose() {}
}
