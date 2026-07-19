import 'dart:io';

import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('RiftDaemon media playback', () {
    late Directory tempDir;
    late RiftDaemon daemon;
    late List<Map<String, dynamic>> ipcEvents;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rift_media_playback');
      ipcEvents = <Map<String, dynamic>>[];
      daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
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
        'payload': {
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
        await daemon.handleMediaPlaybackProtocolMessageForTesting(
          peerDeviceId,
          {
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
          },
        );

        final playback = await daemon.handleJsonRpcRequest({
          'method': 'rift.getMediaPlayback',
          'params': {
            'sourceDeviceId': peerDeviceId,
            'playbackId': 'shared-playback',
          },
        });
        expect(playback['appName'], 'Example Music');

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
            'playbackId': 'local-playback',
            'sourceDeviceId': localDeviceId,
            'requestingDeviceId': peerDeviceId,
            'action': 'unknown',
          },
        },
        {
          'type': 'media.playbackActionRequest',
          'payload': {
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

    test('rejects media identity mismatches without IPC delivery', () async {
      const peerDeviceId = 'rift-peer-device';
      configureMediaPlaybackPeer(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];

      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackActionRequest',
        'messageId': '11111111-1111-4111-8111-111111111111',
        'payload': {
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
            'payload': {
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
            'payload': {
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

    test('expires an unhandled incoming playback action', () async {
      const peerDeviceId = 'rift-peer-device';
      configureMediaPlaybackPeer(peerDeviceId);
      final localDeviceId = daemon.getDeviceInfo()['deviceId'];
      await postLocalPlayback();

      await daemon.handleMediaPlaybackProtocolMessageForTesting(peerDeviceId, {
        'type': 'media.playbackActionRequest',
        'payload': {
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
            'payload': {
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
        expect(params['sourceDeviceId'], localDeviceId);
        expect(params['requestingDeviceId'], peerDeviceId);
        expect(params['action'], 'seek');
        expect(params['positionMs'], 12000);
      },
    );
  });
}
