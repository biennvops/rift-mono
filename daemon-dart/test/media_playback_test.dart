import 'dart:io';

import 'package:daemon_dart/src/daemon.dart';
import 'package:test/test.dart';

void main() {
  group('RiftDaemon media playback', () {
    late Directory tempDir;
    late RiftDaemon daemon;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rift_media_playback');
      daemon = RiftDaemon(
        storagePath: tempDir.path,
        port: 0,
        enableDiscovery: false,
      );
      await daemon.start();
    });

    tearDown(() async {
      await daemon.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
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

      final playbacks = (listed['playbacks'] as List).cast<Map<String, dynamic>>();
      expect(playbacks, hasLength(1));
      expect(playbacks.single['playbackId'], 'playback-1');
      expect(playbacks.single['appName'], 'Example Music');
    });
  });
}
