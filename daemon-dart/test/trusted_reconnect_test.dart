import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';

class _FakeReconnectTransport implements Transport {
  final Map<(String, int), Object> endpointResults = {};
  final List<
    ({String host, int port, String? expectedDeviceId, bool forceFreshSession})
  >
  connectCalls = [];

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async {
    connectCalls.add((
      host: host,
      port: port,
      expectedDeviceId: expectedDeviceId,
      forceFreshSession: forceFreshSession,
    ));
    final result = endpointResults[(host, port)];
    if (result is Exception) {
      throw result;
    }
    if (result is Error) {
      throw result;
    }
    if (result is String) {
      return result;
    }
    return expectedDeviceId ?? 'rift-default';
  }

  @override
  void disconnect(String peerDeviceId) {}

  @override
  Uint8List? getPeerCert(String peerDeviceId) => null;

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) => null;

  @override
  Stream<TransportMessage> get onMessageReceived => const Stream.empty();

  @override
  Stream<String> get onPeerDisconnected => const Stream.empty();

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {}

  @override
  void setPeerAuthenticated(String peerDeviceId) {}

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {}
}

void main() {
  group('trusted reconnect helper', () {
    test('reconnects using first successful persisted endpoint', () async {
      final transport = _FakeReconnectTransport()
        ..endpointResults[('10.53.38.174', 9140)] = 'rift-peer-a';
      final sentHello = <String>[];
      final waited = <String>[];
      final persisted = <(String, String)>[];

      final result = await reconnectTrustedPeerViaEndpoints(
        peerDeviceId: 'rift-peer-a',
        trustedEndpoints: [
          TrustedPeerEndpoint(
            address: '10.53.38.174',
            port: 9140,
            source: 'manual',
            addressFamily: 'IPv4',
            lastSuccessAt: DateTime.utc(2026, 7, 5, 10, 0, 0),
          ),
        ],
        transport: transport,
        getContext: (_) => null,
        sendSessionHello: (peerDeviceId) async => sentHello.add(peerDeviceId),
        waitForSessionEstablished: (peerDeviceId) async =>
            waited.add(peerDeviceId),
        persistTrustedEndpoint: (peerDeviceId, source) async =>
            persisted.add((peerDeviceId, source)),
      );

      expect(result, 'rift-peer-a');
      expect(sentHello, ['rift-peer-a']);
      expect(waited, ['rift-peer-a']);
      expect(persisted, [('rift-peer-a', 'trusted-reconnect')]);
      expect(transport.connectCalls, hasLength(1));
      expect(transport.connectCalls.single.forceFreshSession, isTrue);
    });

    test('falls back to second endpoint when first endpoint fails', () async {
      final transport = _FakeReconnectTransport()
        ..endpointResults[('10.53.38.177', 9140)] = HandshakeException(
          'bad tls',
        )
        ..endpointResults[('10.53.38.178', 9140)] = 'rift-peer-b';
      final persisted = <(String, String)>[];

      final result = await reconnectTrustedPeerViaEndpoints(
        peerDeviceId: 'rift-peer-b',
        trustedEndpoints: [
          TrustedPeerEndpoint(
            address: '10.53.38.177',
            port: 9140,
            source: 'manual',
            addressFamily: 'IPv4',
            lastSuccessAt: DateTime.utc(2026, 7, 5, 10, 0, 0),
          ),
          TrustedPeerEndpoint(
            address: '10.53.38.178',
            port: 9140,
            source: 'fallback',
            addressFamily: 'IPv4',
            lastSuccessAt: DateTime.utc(2026, 7, 5, 10, 0, 5),
          ),
        ],
        transport: transport,
        getContext: (_) => null,
        sendSessionHello: (_) async {},
        waitForSessionEstablished: (_) async {},
        persistTrustedEndpoint: (peerDeviceId, source) async =>
            persisted.add((peerDeviceId, source)),
      );

      expect(result, 'rift-peer-b');
      expect(
        transport.connectCalls.map((call) => (call.host, call.port)).toList(),
        [('10.53.38.177', 9140), ('10.53.38.178', 9140)],
      );
      expect(persisted.single, ('rift-peer-b', 'trusted-reconnect'));
    });

    test('does not send session.hello when context already exists', () async {
      final transport = _FakeReconnectTransport()
        ..endpointResults[('10.53.38.179', 9140)] = 'rift-peer-c';
      final sentHello = <String>[];

      await reconnectTrustedPeerViaEndpoints(
        peerDeviceId: 'rift-peer-c',
        trustedEndpoints: [
          TrustedPeerEndpoint(
            address: '10.53.38.179',
            port: 9140,
            source: 'manual',
            addressFamily: 'IPv4',
            lastSuccessAt: DateTime.utc(2026, 7, 5, 10, 1, 0),
          ),
        ],
        transport: transport,
        getContext: (peerDeviceId) =>
            SessionContext(peerDeviceId: peerDeviceId, isInitiator: true),
        sendSessionHello: (peerDeviceId) async => sentHello.add(peerDeviceId),
        waitForSessionEstablished: (_) async {},
        persistTrustedEndpoint: (_, source) async {},
      );

      expect(sentHello, isEmpty);
    });
  });

  group('single-flight helper', () {
    test('joins concurrent callers onto one in-flight operation', () async {
      final pending = <String, Future<String>>{};
      final completer = Completer<String>();
      var startCount = 0;

      final first = joinSingleFlightOperation<String>(
        key: 'rift-peer-a',
        pendingOperations: pending,
        startOperation: () {
          startCount += 1;
          return completer.future;
        },
      );
      final second = joinSingleFlightOperation<String>(
        key: 'rift-peer-a',
        pendingOperations: pending,
        startOperation: () {
          startCount += 1;
          return Future.value('unexpected');
        },
      );

      expect(startCount, 1);
      expect(pending, contains('rift-peer-a'));

      completer.complete('rift-peer-a');
      final results = await Future.wait([first, second]);

      expect(results, ['rift-peer-a', 'rift-peer-a']);
      expect(startCount, 1);
      expect(pending, isEmpty);
    });

    test(
      'cleans up pending entry after failure so future attempts can retry',
      () async {
        final pending = <String, Future<String>>{};
        var startCount = 0;

        await expectLater(
          joinSingleFlightOperation<String>(
            key: 'rift-peer-b',
            pendingOperations: pending,
            startOperation: () {
              startCount += 1;
              throw const HandshakeException('boom');
            },
          ),
          throwsA(isA<HandshakeException>()),
        );

        expect(startCount, 1);
        expect(pending, isEmpty);

        final result = await joinSingleFlightOperation<String>(
          key: 'rift-peer-b',
          pendingOperations: pending,
          startOperation: () async {
            startCount += 1;
            return 'rift-peer-b';
          },
        );

        expect(result, 'rift-peer-b');
        expect(startCount, 2);
        expect(pending, isEmpty);
      },
    );
  });
}
