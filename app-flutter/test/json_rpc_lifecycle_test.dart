import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:rift/src/ipc/ipc_transport.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JsonRpcRiftClient connection lifecycle', () {
    test('failed transport connect is disconnected before error propagates',
        () async {
      final transport = _LifecycleTransport()
        ..failNextConnect(StateError('connect failed'));
      final client = JsonRpcRiftClient(transport);

      await expectLater(client.connect(), throwsStateError);

      expect(transport.connectionAttempts, 1);
      expect(transport.disconnectCalls, 1);
      expect(client.isConnected, isFalse);
      await client.dispose();
      await transport.dispose();
    });

    test('retry cannot begin until failed-attempt cleanup completes', () async {
      final cleanupGate = Completer<void>();
      final transport = _LifecycleTransport()
        ..failNextConnect(StateError('connect failed'))
        ..blockNextDisconnect(cleanupGate.future);
      final peer = _ControlledPeer();
      final client = JsonRpcRiftClient(
        transport,
        peerFactory: (_) => peer,
      );

      final firstConnect = client.connect();
      final firstExpectation = expectLater(firstConnect, throwsStateError);
      await pumpEventQueue();
      expect(transport.connectionAttempts, 1);
      expect(transport.disconnectCalls, 1);

      final joinedConnect = client.connect();
      final joinedExpectation = expectLater(joinedConnect, throwsStateError);
      await pumpEventQueue();
      expect(transport.connectionAttempts, 1);

      cleanupGate.complete();
      await firstExpectation;
      await joinedExpectation;

      await client.connect();
      expect(transport.connectionAttempts, 2);
      expect(client.isConnected, isTrue);

      await client.dispose();
      peer.completeListen();
      await transport.dispose();
    });

    test('failed peer setup closes peer, output, and transport', () async {
      final transport = _LifecycleTransport();
      final peer = _ControlledPeer(failRegistrationAt: 1);
      final client = JsonRpcRiftClient(
        transport,
        peerFactory: (_) => peer,
      );

      await expectLater(client.connect(), throwsStateError);

      expect(peer.closeCalls, 1);
      expect(transport.lastConnection?.outgoing.isClosed, isTrue);
      expect(transport.disconnectCalls, 1);
      expect(transport.isConnected, isFalse);
      expect(client.isConnected, isFalse);

      await client.dispose();
      await transport.dispose();
    });

    test('stale peer completion cannot tear down replacement', () async {
      final transport = _LifecycleTransport();
      final peers = <_ControlledPeer>[];
      final client = JsonRpcRiftClient(
        transport,
        peerFactory: (_) {
          final peer = _ControlledPeer();
          peers.add(peer);
          return peer;
        },
      );

      await client.connect();
      expect(client.isConnected, isTrue);
      expect(peers, hasLength(1));

      await client.disconnect();
      await client.connect();
      expect(client.isConnected, isTrue);
      expect(transport.connectionAttempts, 2);
      expect(peers, hasLength(2));
      final disconnectsBeforeStaleCompletion = transport.disconnectCalls;

      peers.first.completeListen();
      await Future<void>.delayed(Duration.zero);

      expect(client.isConnected, isTrue);
      expect(transport.isConnected, isTrue);
      expect(transport.disconnectCalls, disconnectsBeforeStaleCompletion);
      expect(transport.connectionAttempts, 2);
      expect(peers.last.closeCalls, 0);

      await client.dispose();
      peers.last.completeListen();
      await transport.dispose();
    });

    test('connect waits for peer close before replacing the transport',
        () async {
      final closeGate = Completer<void>();
      final transport = _LifecycleTransport();
      final peers = <_ControlledPeer>[];
      final client = JsonRpcRiftClient(
        transport,
        peerFactory: (_) {
          final peer = _ControlledPeer(
            closeGate: peers.isEmpty ? closeGate.future : null,
          );
          peers.add(peer);
          return peer;
        },
      );

      await client.connect();
      final disconnect = client.disconnect();
      expect(peers.single.closeCalls, 1);

      final reconnect = client.connect();
      await Future<void>.delayed(Duration.zero);

      expect(transport.connectionAttempts, 1);
      expect(transport.disconnectCalls, 0);
      expect(client.isConnected, isFalse);

      closeGate.complete();
      await Future.wait([disconnect, reconnect]);

      expect(transport.disconnectCalls, 1);
      expect(transport.connectionAttempts, 2);
      expect(transport.isConnected, isTrue);
      expect(client.isConnected, isTrue);
      expect(peers, hasLength(2));

      final disconnectsBeforeStaleCompletion = transport.disconnectCalls;
      peers.first.completeListen();
      await Future<void>.delayed(Duration.zero);
      expect(transport.disconnectCalls, disconnectsBeforeStaleCompletion);
      expect(client.isConnected, isTrue);

      await client.dispose();
      for (final peer in peers) {
        peer.completeListen();
      }
      await transport.dispose();
    });

    test('connect starts a new attempt after invalidated connect finishes',
        () async {
      final connectGate = Completer<void>();
      final transport = _LifecycleTransport()
        ..blockNextConnect(connectGate.future);
      final peers = <_ControlledPeer>[];
      final client = JsonRpcRiftClient(
        transport,
        peerFactory: (_) {
          final peer = _ControlledPeer();
          peers.add(peer);
          return peer;
        },
      );

      final initialConnect = client.connect();
      expect(transport.connectionAttempts, 1);

      final disconnect = client.disconnect();
      final reconnect = client.connect();
      await Future<void>.delayed(Duration.zero);

      expect(transport.connectionAttempts, 1);
      expect(client.isConnected, isFalse);

      connectGate.complete();
      await Future.wait([initialConnect, disconnect, reconnect]);

      expect(transport.disconnectCalls, 1);
      expect(transport.connectionAttempts, 2);
      expect(transport.isConnected, isTrue);
      expect(client.isConnected, isTrue);
      expect(peers, hasLength(1));

      await client.dispose();
      for (final peer in peers) {
        peer.completeListen();
      }
      await transport.dispose();
    });

    test('manual disconnect never schedules reconnect', () {
      fakeAsync((async) {
        final transport = _LifecycleTransport();
        final peer = _ControlledPeer();
        final client = JsonRpcRiftClient(
          transport,
          peerFactory: (_) => peer,
        );

        client.connect();
        async.flushMicrotasks();
        expect(client.isConnected, isTrue);
        final attemptsBeforeDisconnect = transport.connectionAttempts;

        client.disconnect();
        async.flushMicrotasks();
        peer.completeListen();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(client.isConnected, isFalse);
        expect(transport.connectionAttempts, attemptsBeforeDisconnect);

        client.dispose();
        async.flushMicrotasks();
        transport.dispose();
        async.flushMicrotasks();
      });
    });

    test('dispose cannot resurrect the client', () {
      fakeAsync((async) {
        final transport = _LifecycleTransport();
        final peer = _ControlledPeer();
        final client = JsonRpcRiftClient(
          transport,
          peerFactory: (_) => peer,
        );

        client.connect();
        async.flushMicrotasks();
        final attemptsBeforeDispose = transport.connectionAttempts;

        client.dispose();
        async.flushMicrotasks();
        peer.completeListen();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(client.isConnected, isFalse);
        expect(transport.connectionAttempts, attemptsBeforeDispose);
        transport.dispose();
        async.flushMicrotasks();
      });
    });

    test('unexpected current peer completion reconnects normally', () {
      fakeAsync((async) {
        final transport = _LifecycleTransport();
        final peers = <_ControlledPeer>[];
        final client = JsonRpcRiftClient(
          transport,
          peerFactory: (_) {
            final peer = _ControlledPeer();
            peers.add(peer);
            return peer;
          },
        );

        client.connect();
        async.flushMicrotasks();
        expect(client.isConnected, isTrue);

        peers.first.completeListen();
        async.flushMicrotasks();
        expect(client.isConnected, isFalse);
        expect(transport.disconnectCalls, 1);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(transport.connectionAttempts, 2);
        expect(client.isConnected, isTrue);
        expect(peers, hasLength(2));

        client.dispose();
        async.flushMicrotasks();
        peers.last.completeListen();
        async.flushMicrotasks();
        transport.dispose();
        async.flushMicrotasks();
      });
    });
  });
}

class _LifecycleTransport implements IpcTransport {
  final List<_TransportConnection> _connections = [];
  _TransportConnection? _currentConnection;
  Future<void>? _nextConnectGate;
  Future<void>? _nextDisconnectGate;
  Object? _nextConnectError;
  int connectionAttempts = 0;
  int disconnectCalls = 0;
  bool isConnected = false;

  _TransportConnection? get lastConnection =>
      _connections.isEmpty ? null : _connections.last;

  void blockNextConnect(Future<void> gate) {
    _nextConnectGate = gate;
  }

  void blockNextDisconnect(Future<void> gate) {
    _nextDisconnectGate = gate;
  }

  void failNextConnect(Object error) {
    _nextConnectError = error;
  }

  @override
  Future<StreamChannel<String>> connect() async {
    connectionAttempts += 1;
    final connectGate = _nextConnectGate;
    _nextConnectGate = null;
    if (connectGate != null) {
      await connectGate;
    }
    final connectError = _nextConnectError;
    _nextConnectError = null;
    if (connectError != null) {
      throw connectError;
    }
    final connection = _TransportConnection();
    _connections.add(connection);
    _currentConnection = connection;
    isConnected = true;
    return connection.channel;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
    isConnected = false;
    final disconnectGate = _nextDisconnectGate;
    _nextDisconnectGate = null;
    if (disconnectGate != null) {
      await disconnectGate;
    }
    final connection = _currentConnection;
    _currentConnection = null;
    await connection?.close();
  }

  Future<void> dispose() async {
    for (final connection in _connections) {
      await connection.close();
    }
  }
}

class _TransportConnection {
  final incoming = StreamController<String>.broadcast();
  final outgoing = StreamController<String>.broadcast();
  late final StreamChannel<String> channel = StreamChannel<String>(
    incoming.stream,
    outgoing.sink,
  );

  Future<void> close() async {
    if (!incoming.isClosed) {
      await incoming.close();
    }
    if (!outgoing.isClosed) {
      await outgoing.close();
    }
  }
}

class _ControlledPeer implements json_rpc.Peer {
  _ControlledPeer({this.closeGate, this.failRegistrationAt});

  final Future<void>? closeGate;
  final int? failRegistrationAt;
  final Completer<void> _listenCompleter = Completer<void>();
  bool _isClosed = false;
  int closeCalls = 0;
  int _registrationCalls = 0;

  void completeListen() {
    if (!_listenCompleter.isCompleted) {
      _listenCompleter.complete();
    }
  }

  @override
  Future<void> listen() => _listenCompleter.future;

  @override
  Future<void> close() async {
    closeCalls += 1;
    _isClosed = true;
    await closeGate;
  }

  @override
  Future<void> get done => _listenCompleter.future;

  @override
  bool get isClosed => _isClosed;

  @override
  json_rpc.ErrorCallback? get onUnhandledError => null;

  @override
  bool get strictProtocolChecks => true;

  @override
  void registerMethod(String name, Function callback) {
    _registrationCalls += 1;
    if (_registrationCalls == failRegistrationAt) {
      throw StateError('peer registration failed');
    }
  }

  @override
  void registerFallback(void Function(json_rpc.Parameters) callback) {}

  @override
  Future<Object?> sendRequest(String method, [Object? parameters]) =>
      throw UnimplementedError();

  @override
  void sendNotification(String method, [Object? parameters]) =>
      throw UnimplementedError();

  @override
  void withBatch(void Function() callback) => callback();
}
