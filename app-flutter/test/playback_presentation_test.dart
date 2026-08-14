import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/media_playback/playback_presentation.dart';

Map<String, dynamic> playback({
  required String sourceDeviceId,
  required String playbackId,
  required String state,
  required String updatedAt,
}) {
  return {
    'sourceDeviceId': sourceDeviceId,
    'playbackId': playbackId,
    'appName': 'Player',
    'playbackState': state,
    'updatedAt': updatedAt,
  };
}

void main() {
  test('selects playing and paused sessions but ignores stopped sessions', () {
    final playing = playback(
      sourceDeviceId: 'peer-a',
      playbackId: 'playing',
      state: 'playing',
      updatedAt: '2026-08-01T10:00:00Z',
    );
    final paused = playback(
      sourceDeviceId: 'peer-a',
      playbackId: 'paused',
      state: 'paused',
      updatedAt: '2026-08-01T10:01:00Z',
    );
    final stopped = playback(
      sourceDeviceId: 'peer-a',
      playbackId: 'stopped',
      state: 'stopped',
      updatedAt: '2026-08-01T10:02:00Z',
    );

    expect(
      selectCurrentPlaybackForDevice([playing], 'peer-a'),
      same(playing),
    );
    expect(
      selectCurrentPlaybackForDevice([paused], 'peer-a'),
      same(paused),
    );
    expect(
      selectCurrentPlaybackForDevice([stopped], 'peer-a'),
      isNull,
    );
  });

  test('newest non-stopped session wins regardless of playback state', () {
    final olderPlaying = playback(
      sourceDeviceId: 'peer-a',
      playbackId: 'playing',
      state: 'playing',
      updatedAt: '2026-08-01T10:00:00Z',
    );
    final newerPaused = playback(
      sourceDeviceId: 'peer-a',
      playbackId: 'paused',
      state: 'paused',
      updatedAt: '2026-08-01T10:01:00Z',
    );
    final newestPlaying = playback(
      sourceDeviceId: 'peer-a',
      playbackId: 'new-playing',
      state: 'playing',
      updatedAt: '2026-08-01T10:02:00Z',
    );

    expect(
      selectCurrentPlaybackForDevice(
        [olderPlaying, newerPaused],
        'peer-a',
      ),
      same(newerPaused),
    );
    expect(
      selectCurrentPlaybackForDevice(
        [olderPlaying, newerPaused, newestPlaying],
        'peer-a',
      ),
      same(newestPlaying),
    );
  });

  test('removing the current session reveals the next eligible session', () {
    final sessions = <Map<String, dynamic>>[
      playback(
        sourceDeviceId: 'peer-a',
        playbackId: 'older',
        state: 'paused',
        updatedAt: '2026-08-01T10:00:00Z',
      ),
      playback(
        sourceDeviceId: 'peer-a',
        playbackId: 'newer',
        state: 'playing',
        updatedAt: '2026-08-01T10:01:00Z',
      ),
    ];

    expect(
      selectCurrentPlaybackForDevice(sessions, 'peer-a')?['playbackId'],
      'newer',
    );
    sessions.removeWhere((item) => item['playbackId'] == 'newer');
    expect(
      selectCurrentPlaybackForDevice(sessions, 'peer-a')?['playbackId'],
      'older',
    );
    sessions.clear();
    expect(selectCurrentPlaybackForDevice(sessions, 'peer-a'), isNull);
  });

  test('selection is isolated by source device', () {
    final peerA = playback(
      sourceDeviceId: 'peer-a',
      playbackId: 'shared-id',
      state: 'playing',
      updatedAt: '2026-08-01T10:00:00Z',
    );
    final peerB = playback(
      sourceDeviceId: 'peer-b',
      playbackId: 'shared-id',
      state: 'paused',
      updatedAt: '2026-08-01T10:02:00Z',
    );

    expect(
      selectCurrentPlaybackForDevice([peerA, peerB], 'peer-a'),
      same(peerA),
    );
    expect(
      selectCurrentPlaybackForDevice([peerA, peerB], 'peer-b'),
      same(peerB),
    );
    expect(mediaPlaybackKey(peerA), 'peer-a:shared-id');
    expect(mediaPlaybackKey(peerB), 'peer-b:shared-id');
  });
}
