import 'dart:async';

import 'package:flutter/services.dart';
import 'package:stream_channel/stream_channel.dart';

import 'ipc_transport.dart';

class BufferedBroadcastStream<T> {
  final List<T> _pending = [];

  late final StreamController<T> _controller =
      StreamController<T>.broadcast(onListen: _flush);

  Stream<T> get stream => _controller.stream;

  void add(T value) {
    if (_controller.hasListener) {
      _controller.add(value);
    } else {
      _pending.add(value);
    }
  }

  void addError(Object error, [StackTrace? stackTrace]) {
    _controller.addError(error, stackTrace);
  }

  Future<void> close() async {
    _pending.clear();
    await _controller.close();
  }

  void _flush() {
    final pending = List<T>.of(_pending);
    _pending.clear();
    for (final value in pending) {
      _controller.add(value);
    }
  }
}

class AndroidServiceTransport implements IpcTransport {
  static const _controlChannel = MethodChannel('rift/android/service_rpc');
  static const _eventChannel = EventChannel('rift/android/service_rpc_events');

  StreamSubscription<dynamic>? _eventSubscription;
  BufferedBroadcastStream<String>? _incoming;
  StreamController<String>? _outgoing;
  bool _connected = false;

  @override
  Future<StreamChannel<String>> connect() async {
    if (_connected && _incoming != null && _outgoing != null) {
      return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
    }

    final incoming = BufferedBroadcastStream<String>();
    final outgoing = StreamController<String>();
    _incoming = incoming;
    _outgoing = outgoing;

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (message) {
        if (message is String) {
          incoming.add(message);
        }
      },
      onError: incoming.addError,
      onDone: incoming.close,
    );
    outgoing.stream.listen(
      (message) {
        unawaited(_controlChannel.invokeMethod<void>('send', message));
      },
      onError: incoming.addError,
    );

    try {
      await _controlChannel.invokeMethod<void>('attach');
      _connected = true;
      return StreamChannel<String>(incoming.stream, outgoing.sink);
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _outgoing?.close();
    await _incoming?.close();
    _outgoing = null;
    _incoming = null;
    try {
      await _controlChannel.invokeMethod<void>('detach');
    } catch (_) {
      // The service may already be gone during process teardown.
    }
  }
}
