import 'dart:async';

import 'package:flutter/services.dart';
import 'package:stream_channel/stream_channel.dart';

import 'ipc_transport.dart';

class AndroidServiceTransport implements IpcTransport {
  static const _controlChannel = MethodChannel('rift/android/service_rpc');
  static const _eventChannel = EventChannel('rift/android/service_rpc_events');

  StreamSubscription<dynamic>? _eventSubscription;
  StreamController<String>? _incoming;
  StreamController<String>? _outgoing;
  bool _connected = false;

  @override
  Future<StreamChannel<String>> connect() async {
    if (_connected && _incoming != null && _outgoing != null) {
      return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
    }

    final incoming = StreamController<String>.broadcast();
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
