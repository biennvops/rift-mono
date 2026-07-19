import 'dart:io';

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
      );
      await daemon.start();
    });

    tearDown(() async {
      await daemon.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

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

    test(
      'delivers trusted peer action requests to the local IPC client',
      () async {
        const peerDeviceId = 'rift-peer-device';
        configureMediaPlaybackPeer(peerDeviceId);
        final localDeviceId = daemon.getDeviceInfo()['deviceId'];

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
