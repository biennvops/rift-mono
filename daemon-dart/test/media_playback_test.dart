import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';

class RecordingMediaPlaybackTransport implements Transport {
  final _onMessage = StreamController<TransportMessage>.broadcast();
  final _onDisconnect = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sentMessages = [];

  @override
  Stream<TransportMessage> get onMessageReceived => _onMessage.stream;

  @override
  Stream<String> get onPeerDisconnected => _onDisconnect.stream;

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async => expectedDeviceId ?? 'rift-peer';

  @override
  void disconnect(String peerDeviceId) {
    _onDisconnect.add(peerDeviceId);
  }

  @override
  Uint8List? getPeerCert(String peerDeviceId) => Uint8List(32);

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) =>
      const PeerSocketEndpoint(address: '127.0.0.1', port: 1);

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    sentMessages.add(json.decode(utf8.decode(message)) as Map<String, dynamic>);
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {}

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {
    await _onMessage.close();
    await _onDisconnect.close();
  }
}

void main() {
  group('RiftDaemon media playback', () {
    const incomingOperationId = '018f2f9a-8b7c-4a4b-9c0d-aaaaaaaaaaaa';
    late Directory tempDir;
    late RiftDaemon daemon;
    late List<Map<String, dynamic>> ipcEvents;
    late RecordingMediaPlaybackTransport transport;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rift_media_playback');
      ipcEvents = <Map<String, dynamic>>[];
      transport = RecordingMediaPlaybackTransport();
      daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
        peerTransport: transport,
        onIpcEvent: ipcEvents.add,
        mediaPlaybackActionTimeout: const Duration(milliseconds: 50),
      );
      await daemon.start();
    });

    tearDown(() async {
      await daemon.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<void> postLocalPlayback({
      String playbackId = 'local-playback',
      bool canPause = true,
      bool canSeek = true,
    }) async {
      await daemon.handleJsonRpcRequest({
        'method': 'rift.notifyLocalMediaPlaybackEvent',
        'params': {
          'eventType': 'posted',
          'playbackId': playbackId,
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00.000Z',
          'canPlay': true,
          'canPause': canPause,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': canSeek,
        },
      });
    }

    void configureMediaPlaybackPeer(String peerDeviceId) {
      final context =
          SessionContext(peerDeviceId: peerDeviceId, isInitiator: false)
            ..handshakeState = HandshakeState.established
            ..trustState = TrustState.trusted
            ..capabilityNegotiated = true
            ..negotiatedCapabilities = [
              Capability(name: 'media.playback', version: 1),
            ];
      daemon.sessionManagerForTesting.injectContextForTesting(context);
    }

    Future<void> configureOutgoingMediaPlaybackPeer(String peerDeviceId) async {
      configureMediaPlaybackPeer(peerDeviceId);
      await daemon.trustStoreForTesting.upsertPeer(
        PeerRecord(
          deviceId: peerDeviceId,
          certDer: Uint8List(32),
          state: TrustState.trusted,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }

    Future<void> postRemotePlayback(
      String peerDeviceId, {
      String playbackId = 'remote-playback',
    }) {
      return daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackPosted',
        'payload': {
          'playbackId': playbackId,
          'sourceDeviceId': peerDeviceId,
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00.000Z',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      });
    }

    test('normalizes and validates playback failure reasons', () {
      expect(
        daemon.normalizeMediaPlaybackFailureReasonForTesting(
          success: false,
          failureReason: null,
          invalidCode: -32010,
        ),
        'PeerRejected',
      );
      expect(
        () => daemon.normalizeMediaPlaybackFailureReasonForTesting(
          success: true,
          failureReason: 'not-allowed',
          invalidCode: -32010,
        ),
        throwsA(isA<RiftException>()),
      );
      expect(
        () => daemon.normalizeMediaPlaybackFailureReasonForTesting(
          success: true,
          failureReason: 123,
          invalidCode: -32010,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        daemon.normalizeMediaPlaybackFailureReasonForTesting(
          success: true,
          failureReason: 'PeerRejected',
          invalidCode: -32010,
        ),
        isNull,
      );
    });

    test('requires full RFC 3339 UTC playback timestamps', () async {
      for (final updatedAt in const [
        '2026-07-16',
        '2026-07-16T10:00:00',
        '2026-07-16T10:00:00+01:00',
        '2026-02-30T10:00:00Z',
        '07/16/2026',
      ]) {
        await expectLater(
          daemon.handleJsonRpcRequest({
            'method': 'rift.notifyLocalMediaPlaybackEvent',
            'params': {
              'eventType': 'posted',
              'playbackId': 'invalid-$updatedAt',
              'appId': 'com.example.music',
              'appName': 'Example Music',
              'playbackState': 'playing',
              'positionMs': 1000,
              'updatedAt': updatedAt,
              'canPlay': true,
              'canPause': true,
              'canSkipNext': true,
              'canSkipPrevious': true,
              'canSeek': true,
            },
          }),
          throwsA(anything),
        );
      }

      final result = await daemon.handleJsonRpcRequest({
        'method': 'rift.notifyLocalMediaPlaybackEvent',
        'params': {
          'eventType': 'posted',
          'playbackId': 'utc-offset',
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00+00:00',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      });
      expect(result['playbackId'], 'utc-offset');
    });

    test('stores local posted playback and returns list state', () async {
      final result = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'rift.notifyLocalMediaPlaybackEvent',
        'params': {
          'eventType': 'posted',
          'playbackId': 'playback-1',
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00.000Z',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      });

      expect(result['playbackId'], 'playback-1');

      final listed = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'rift.listMediaPlayback',
      });

      final playbacks = (listed['playbacks'] as List)
          .cast<Map<String, dynamic>>();
      expect(playbacks, hasLength(1));
      expect(playbacks.single['playbackId'], 'playback-1');
      expect(playbacks.single['appName'], 'Example Music');
    });

    test('gets playback by source device and playback ID', () async {
      await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'rift.notifyLocalMediaPlaybackEvent',
        'params': {
          'eventType': 'posted',
          'playbackId': 'playback-1',
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00.000Z',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      });
      final listed = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'rift.listMediaPlayback',
      });
      final playback =
          (listed['playbacks'] as List).single as Map<String, dynamic>;

      final result = await daemon.handleJsonRpcRequest({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'rift.getMediaPlayback',
        'params': {
          'sourceDeviceId': playback['sourceDeviceId'],
          'playbackId': 'playback-1',
        },
      });

      expect(result['sourceDeviceId'], playback['sourceDeviceId']);
      expect(result['playbackId'], 'playback-1');
    });

    test(
      'accepts removal with only playback ID and optional timestamp',
      () async {
        await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'rift.notifyLocalMediaPlaybackEvent',
          'params': {
            'eventType': 'posted',
            'playbackId': 'playback-1',
            'appId': 'com.example.music',
            'appName': 'Example Music',
            'playbackState': 'playing',
            'positionMs': 1000,
            'updatedAt': '2026-07-16T10:00:00.000Z',
            'canPlay': true,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
          },
        });

        final result = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'rift.notifyLocalMediaPlaybackEvent',
          'params': {
            'eventType': 'removed',
            'playbackId': 'playback-1',
            'removedAt': '2026-07-16T10:01:00.000Z',
          },
        });

        expect(result['playbackId'], 'playback-1');
        final listed = await daemon.handleJsonRpcRequest({
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'rift.listMediaPlayback',
        });
        expect(listed['playbacks'], isEmpty);
      },
    );

    test('rejects malformed optional media timestamps', () async {
      await expectLater(
        daemon.handleJsonRpcRequest({
          'method': 'rift.notifyLocalMediaPlaybackEvent',
          'params': {
            'eventType': 'removed',
            'playbackId': 'playback-1',
            'removedAt': '2026-07-16T10:00:00',
          },
        }),
        throwsA(isA<ArgumentError>()),
      );

      const peerDeviceId = 'rift-peer-device';
      configureMediaPlaybackPeer(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];
      await postLocalPlayback();
      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackActionRequest',
        'operationId': incomingOperationId,
        'payload': {
          'operationId': incomingOperationId,
          'playbackId': 'local-playback',
          'sourceDeviceId': localDeviceId,
          'requestingDeviceId': peerDeviceId,
          'action': 'pause',
          'requestedAt': '2026-07-16',
        },
      });
      expect(
        ipcEvents.where(
          (event) => event['method'] == 'rift.onMediaPlaybackActionRequest',
        ),
        isEmpty,
      );

      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackPosted',
        'payload': {
          'playbackId': 'shared-playback',
          'sourceDeviceId': peerDeviceId,
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00Z',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      });
      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackRemoved',
        'payload': {
          'playbackId': 'shared-playback',
          'sourceDeviceId': peerDeviceId,
          'removedAt': '2026-07-16T10:00:00+01:00',
        },
      });
      final listed = await daemon.handleJsonRpcRequest({
        'method': 'rift.listMediaPlayback',
      });
      expect(
        (listed['playbacks'] as List).where(
          (playback) => playback['playbackId'] == 'shared-playback',
        ),
        hasLength(1),
      );
    });

    test(
      'accepts posted and minimal removed records from a trusted peer',
      () async {
        const peerDeviceId = 'rift-peer-device';
        configureMediaPlaybackPeer(peerDeviceId);
        await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
          'type': 'media.playbackPosted',
          'payload': {
            'playbackId': 'shared-playback',
            'sourceDeviceId': peerDeviceId,
            'appId': 'com.example.music',
            'appName': 'Example Music',
            'artwork': {
              'mediaType': 'image/png',
              'dataBase64': 'AQID',
              'byteSize': 3,
              'sha256':
                  '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
            },
            'playbackState': 'playing',
            'positionMs': 1000,
            'updatedAt': '2026-07-16T10:00:00.000Z',
            'canPlay': true,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
          },
        });

        final playback = await daemon.handleJsonRpcRequest({
          'method': 'rift.getMediaPlayback',
          'params': {
            'sourceDeviceId': peerDeviceId,
            'playbackId': 'shared-playback',
          },
        });
        expect(playback['appName'], 'Example Music');
        expect(playback['artwork'], {
          'mediaType': 'image/png',
          'dataBase64': 'AQID',
          'byteSize': 3,
          'sha256':
              '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
        });

        await daemon.handleMediaPlaybackProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'media.playbackRemoved',
            'payload': {
              'playbackId': 'shared-playback',
              'sourceDeviceId': peerDeviceId,
              'removedAt': '2026-07-16T10:01:00.000Z',
            },
          },
        );

        final listed = await daemon.handleJsonRpcRequest({
          'method': 'rift.listMediaPlayback',
        });
        expect(listed['playbacks'], isEmpty);
        final removed = ipcEvents.lastWhere(
          (event) => event['method'] == 'rift.onMediaPlaybackRemoved',
        );
        expect(removed['params'], {
          'playbackId': 'shared-playback',
          'sourceDeviceId': peerDeviceId,
          'removedAt': '2026-07-16T10:01:00.000Z',
        });
      },
    );

    test(
      'preserves pending artwork hints through daemon state and IPC',
      () async {
        const peerDeviceId = 'rift-peer-device';
        configureMediaPlaybackPeer(peerDeviceId);
        await daemon.handleMediaPlaybackProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'media.playbackPosted',
            'payload': {
              'playbackId': 'pending-playback',
              'sourceDeviceId': peerDeviceId,
              'appId': 'com.example.music',
              'appName': 'Example Music',
              'artworkPending': true,
              'playbackState': 'playing',
              'positionMs': 1000,
              'updatedAt': '2026-07-16T10:00:00.000Z',
              'canPlay': true,
              'canPause': true,
              'canSkipNext': true,
              'canSkipPrevious': true,
              'canSeek': true,
            },
          },
        );

        final playback = await daemon.handleJsonRpcRequest({
          'method': 'rift.getMediaPlayback',
          'params': {
            'sourceDeviceId': peerDeviceId,
            'playbackId': 'pending-playback',
          },
        });
        expect(playback['artwork'], isNull);
        expect(playback['artworkPending'], isTrue);
        final posted = ipcEvents.lastWhere(
          (event) => event['method'] == 'rift.onMediaPlaybackPosted',
        );
        expect((posted['params'] as Map)['artworkPending'], isTrue);
      },
    );

    test('clears remote playback when its peer session disconnects', () async {
      const peerDeviceId = 'rift-peer-device';
      configureMediaPlaybackPeer(peerDeviceId);
      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackPosted',
        'payload': {
          'playbackId': 'shared-playback',
          'sourceDeviceId': peerDeviceId,
          'appId': 'com.example.music',
          'appName': 'Example Music',
          'playbackState': 'playing',
          'positionMs': 1000,
          'updatedAt': '2026-07-16T10:00:00.000Z',
          'canPlay': true,
          'canPause': true,
          'canSkipNext': true,
          'canSkipPrevious': true,
          'canSeek': true,
        },
      });

      daemon.sessionManagerForTesting.disconnectPeer(peerDeviceId);
      await Future<void>.delayed(Duration.zero);

      final listed = await daemon.handleJsonRpcRequest({
        'method': 'rift.listMediaPlayback',
      });
      expect(listed['playbacks'], isEmpty);
    });

    test('drops malformed peer playback messages without throwing', () async {
      const peerDeviceId = 'rift-peer-device';
      configureMediaPlaybackPeer(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];

      final malformedEnvelopes = <Map<String, dynamic>>[
        {
          'type': 'media.playbackPosted',
          'payload': {
            'playbackId': 'shared-playback',
            'sourceDeviceId': peerDeviceId,
            'appId': 'com.example.music',
            'appName': 'Example Music',
            'playbackState': 'invalid',
            'positionMs': 1000,
            'updatedAt': '2026-07-16T10:00:00.000Z',
            'canPlay': true,
            'canPause': true,
            'canSkipNext': true,
            'canSkipPrevious': true,
            'canSeek': true,
          },
        },
        {
          'type': 'media.playbackActionRequest',
          'payload': {
            'operationId': incomingOperationId,
            'playbackId': 'local-playback',
            'sourceDeviceId': localDeviceId,
            'requestingDeviceId': peerDeviceId,
            'action': 'pause',
          },
        },
        {
          'type': 'media.playbackActionRequest',
          'operationId': incomingOperationId,
          'payload': {
            'operationId': incomingOperationId,
            'playbackId': 'local-playback',
            'sourceDeviceId': localDeviceId,
            'requestingDeviceId': peerDeviceId,
            'action': 'unknown',
          },
        },
        {
          'type': 'media.playbackActionRequest',
          'operationId': incomingOperationId,
          'payload': {
            'operationId': incomingOperationId,
            'playbackId': 'local-playback',
            'sourceDeviceId': localDeviceId,
            'requestingDeviceId': peerDeviceId,
            'action': 'seek',
            'positionMs': -1,
          },
        },
      ];

      for (final envelope in malformedEnvelopes) {
        await expectLater(
          daemon.handleMediaPlaybackProtocolMessageForTesting(
            peerDeviceId,
            envelope,
          ),
          completes,
        );
      }

      final listed = await daemon.handleJsonRpcRequest({
        'method': 'rift.listMediaPlayback',
      });
      expect(listed['playbacks'], isEmpty);
      expect(
        ipcEvents.where(
          (event) => event['method'] == 'rift.onMediaPlaybackActionRequest',
        ),
        isEmpty,
      );
    });

    test(
      'rejects mismatched media operation IDs without IPC delivery',
      () async {
        const peerDeviceId = 'rift-peer-device';
        configureMediaPlaybackPeer(peerDeviceId);
        final localDeviceId = daemon.getDeviceInfo()['deviceId'];

        await daemon.handleMediaPlaybackProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'media.playbackActionRequest',
            'messageId': '11111111-1111-4111-8111-111111111111',
            'operationId': incomingOperationId,
            'payload': {
              'operationId': '018f2f9a-8b7c-4a4b-9c0d-bbbbbbbbbbbb',
              'playbackId': 'local-playback',
              'sourceDeviceId': localDeviceId,
              'requestingDeviceId': peerDeviceId,
              'action': 'pause',
            },
          },
        );

        expect(
          ipcEvents.where(
            (event) => event['method'] == 'rift.onMediaPlaybackActionRequest',
          ),
          isEmpty,
        );
        final error = transport.sentMessages.singleWhere(
          (message) => message['type'] == 'error',
        );
        expect(error['payload']['failureReason'], 'ProtocolError');
      },
    );

    test('rejects media identity mismatches without IPC delivery', () async {
      const peerDeviceId = 'rift-peer-device';
      configureMediaPlaybackPeer(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];

      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackActionRequest',
        'messageId': '11111111-1111-4111-8111-111111111111',
        'operationId': incomingOperationId,
        'payload': {
          'operationId': incomingOperationId,
          'playbackId': 'local-playback',
          'sourceDeviceId': localDeviceId,
          'requestingDeviceId': 'rift-spoofed',
          'action': 'pause',
        },
      });

      expect(
        ipcEvents.where(
          (event) => event['method'] == 'rift.onMediaPlaybackActionRequest',
        ),
        isEmpty,
      );
    });

    test(
      'rejects missing and disallowed local playback action requests',
      () async {
        const peerDeviceId = 'rift-peer-device';
        configureMediaPlaybackPeer(peerDeviceId);
        final localDeviceId = daemon.getDeviceInfo()['deviceId'];

        await daemon.handleMediaPlaybackProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'media.playbackActionRequest',
            'operationId': incomingOperationId,
            'payload': {
              'operationId': incomingOperationId,
              'playbackId': 'missing-playback',
              'sourceDeviceId': localDeviceId,
              'requestingDeviceId': peerDeviceId,
              'action': 'pause',
            },
          },
        );
        await postLocalPlayback(playbackId: 'restricted', canSeek: false);
        await daemon.handleMediaPlaybackProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'media.playbackActionRequest',
            'operationId': incomingOperationId,
            'payload': {
              'operationId': incomingOperationId,
              'playbackId': 'restricted',
              'sourceDeviceId': localDeviceId,
              'requestingDeviceId': peerDeviceId,
              'action': 'seek',
              'positionMs': 12000,
            },
          },
        );

        expect(
          ipcEvents.where(
            (event) => event['method'] == 'rift.onMediaPlaybackActionRequest',
          ),
          isEmpty,
        );
      },
    );

    test(
      'puts the requester operation ID on the action wire payload',
      () async {
        const peerDeviceId = 'rift-peer-device';
        await configureOutgoingMediaPlaybackPeer(peerDeviceId);
        await postRemotePlayback(peerDeviceId);

        final result = await daemon.handleJsonRpcRequest({
          'method': 'rift.performMediaPlaybackAction',
          'params': {
            'sourceDeviceId': peerDeviceId,
            'playbackId': 'remote-playback',
            'action': 'pause',
          },
        });

        final request = transport.sentMessages.singleWhere(
          (message) => message['type'] == 'media.playbackActionRequest',
        );
        expect(request['operationId'], result['operationId']);
        expect(request['payload']['operationId'], result['operationId']);
      },
    );

    test('late media action result cannot complete a retry', () async {
      const peerDeviceId = 'rift-peer-device';
      await configureOutgoingMediaPlaybackPeer(peerDeviceId);
      await postRemotePlayback(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];

      Future<Map<String, dynamic>> performPause() =>
          daemon.handleJsonRpcRequest({
            'method': 'rift.performMediaPlaybackAction',
            'params': {
              'sourceDeviceId': peerDeviceId,
              'playbackId': 'remote-playback',
              'action': 'pause',
            },
          });
      Future<void> deliverResult(String operationId) =>
          daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
            'type': 'media.playbackActionResult',
            'operationId': operationId,
            'payload': {
              'operationId': operationId,
              'playbackId': 'remote-playback',
              'sourceDeviceId': peerDeviceId,
              'requestingDeviceId': localDeviceId,
              'action': 'pause',
              'success': true,
            },
          });

      final first = await performPause();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final retry = await performPause();
      expect(retry['operationId'], isNot(first['operationId']));

      await deliverResult(first['operationId'] as String);
      final stillPending = await daemon.handleJsonRpcRequest({
        'method': 'rift.getOperation',
        'params': {'operationId': retry['operationId']},
      });
      expect(stillPending['state'], 'Dispatched');

      await deliverResult(retry['operationId'] as String);
      final completed = await daemon.handleJsonRpcRequest({
        'method': 'rift.getOperation',
        'params': {'operationId': retry['operationId']},
      });
      expect(completed['state'], 'Done');
    });

    test('mismatched action result leaves its operation pending', () async {
      const peerDeviceId = 'rift-peer-device';
      await configureOutgoingMediaPlaybackPeer(peerDeviceId);
      await postRemotePlayback(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];
      final pending = await daemon.handleJsonRpcRequest({
        'method': 'rift.performMediaPlaybackAction',
        'params': {
          'sourceDeviceId': peerDeviceId,
          'playbackId': 'remote-playback',
          'action': 'pause',
        },
      });

      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackActionResult',
        'operationId': pending['operationId'],
        'payload': {
          'operationId': pending['operationId'],
          'playbackId': 'different-playback',
          'sourceDeviceId': peerDeviceId,
          'requestingDeviceId': localDeviceId,
          'action': 'pause',
          'success': true,
        },
      });

      final operation = await daemon.handleJsonRpcRequest({
        'method': 'rift.getOperation',
        'params': {'operationId': pending['operationId']},
      });
      expect(operation['state'], 'Dispatched');
    });

    test('duplicate guard is not used to correlate unknown results', () async {
      const peerDeviceId = 'rift-peer-device';
      await configureOutgoingMediaPlaybackPeer(peerDeviceId);
      await postRemotePlayback(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];
      final pending = await daemon.handleJsonRpcRequest({
        'method': 'rift.performMediaPlaybackAction',
        'params': {
          'sourceDeviceId': peerDeviceId,
          'playbackId': 'remote-playback',
          'action': 'pause',
        },
      });

      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackActionResult',
        'operationId': '018f2f9a-8b7c-4a4b-9c0d-bbbbbbbbbbbb',
        'payload': {
          'operationId': '018f2f9a-8b7c-4a4b-9c0d-bbbbbbbbbbbb',
          'playbackId': 'remote-playback',
          'sourceDeviceId': peerDeviceId,
          'requestingDeviceId': localDeviceId,
          'action': 'pause',
          'success': true,
        },
      });

      final operation = await daemon.handleJsonRpcRequest({
        'method': 'rift.getOperation',
        'params': {'operationId': pending['operationId']},
      });
      expect(operation['state'], 'Dispatched');
      await expectLater(
        daemon.handleJsonRpcRequest({
          'method': 'rift.performMediaPlaybackAction',
          'params': {
            'sourceDeviceId': peerDeviceId,
            'playbackId': 'remote-playback',
            'action': 'pause',
          },
        }),
        throwsA(isA<RiftException>()),
      );
    });

    test('expires an unhandled incoming playback action', () async {
      const peerDeviceId = 'rift-peer-device';
      configureMediaPlaybackPeer(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];
      await postLocalPlayback();

      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackActionRequest',
        'operationId': incomingOperationId,
        'payload': {
          'operationId': incomingOperationId,
          'playbackId': 'local-playback',
          'sourceDeviceId': localDeviceId,
          'requestingDeviceId': peerDeviceId,
          'action': 'pause',
        },
      });
      final request = ipcEvents.singleWhere(
        (event) => event['method'] == 'rift.onMediaPlaybackActionRequest',
      );
      final requestId =
          (request['params'] as Map<String, dynamic>)['requestId'];

      await Future<void>.delayed(const Duration(milliseconds: 150));

      await expectLater(
        daemon.handleJsonRpcRequest({
          'method': 'rift.reportLocalMediaPlaybackActionHandled',
          'params': {'requestId': requestId, 'success': true},
        }),
        throwsA(isA<RiftException>()),
      );
    });

    test(
      'delivers trusted peer action requests to the local IPC client',
      () async {
        const peerDeviceId = 'rift-peer-device';
        configureMediaPlaybackPeer(peerDeviceId);
        final localDeviceId = daemon.getDeviceInfo()['deviceId'];
        await postLocalPlayback();

        await daemon.handleMediaPlaybackProtocolMessageForTesting(
          peerDeviceId,
          {
            'type': 'media.playbackActionRequest',
            'operationId': incomingOperationId,
            'payload': {
              'operationId': incomingOperationId,
              'playbackId': 'local-playback',
              'sourceDeviceId': localDeviceId,
              'requestingDeviceId': peerDeviceId,
              'action': 'seek',
              'positionMs': 12000,
            },
          },
        );

        final request = ipcEvents.singleWhere(
          (event) => event['method'] == 'rift.onMediaPlaybackActionRequest',
        );
        final params = request['params'] as Map<String, dynamic>;
        expect(params['requestId'], isNotEmpty);
        expect(params['operationId'], incomingOperationId);
        expect(params['sourceDeviceId'], localDeviceId);
        expect(params['requestingDeviceId'], peerDeviceId);
        expect(params['action'], 'seek');
        expect(params['positionMs'], 12000);

        await daemon.handleJsonRpcRequest({
          'method': 'rift.reportLocalMediaPlaybackActionHandled',
          'params': {'requestId': params['requestId'], 'success': true},
        });
        final result = transport.sentMessages.singleWhere(
          (message) => message['type'] == 'media.playbackActionResult',
        );
        expect(result['operationId'], incomingOperationId);
        expect(result['payload']['operationId'], incomingOperationId);
      },
    );
  });
}
