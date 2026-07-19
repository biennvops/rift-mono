import 'dart:async';

import 'media_playback_models.dart';

class MediaPlaybackManager {
  final Map<String, MediaPlaybackRecord> _playbacks = {};
  final _postedController = StreamController<MediaPlaybackRecord>.broadcast();
  final _updatedController = StreamController<MediaPlaybackRecord>.broadcast();
  final _removedController = StreamController<MediaPlaybackRecord>.broadcast();
  final _actionResultController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<MediaPlaybackRecord> get onPosted => _postedController.stream;
  Stream<MediaPlaybackRecord> get onUpdated => _updatedController.stream;
  Stream<MediaPlaybackRecord> get onRemoved => _removedController.stream;
  Stream<Map<String, dynamic>> get onActionResult =>
      _actionResultController.stream;

  void dispose() {
    _postedController.close();
    _updatedController.close();
    _removedController.close();
    _actionResultController.close();
  }

  Map<String, dynamic> listStateJson() => {
    'playbacks': _playbacks.values
        .where((p) => !p.isRemoved)
        .map((p) => p.toJson())
        .toList(growable: false),
  };

  MediaPlaybackRecord? getPlayback(String sourceDeviceId, String playbackId) {
    final playback = _playbacks[_key(sourceDeviceId, playbackId)];
    return playback == null || playback.isRemoved ? null : playback;
  }

  Map<String, dynamic> notifyLocalEvent(
    String eventType,
    MediaPlaybackRecord record,
  ) {
    final key = _key(record.sourceDeviceId, record.playbackId);
    switch (eventType) {
      case 'posted':
        _playbacks[key] = record;
        _postedController.add(record);
        break;
      case 'updated':
        _playbacks[key] = record;
        _updatedController.add(record);
        break;
      case 'removed':
        return removePlayback(
          record.sourceDeviceId,
          record.playbackId,
          removedAt: record.removedAt,
        );
      default:
        throw ArgumentError.value(
          eventType,
          'eventType',
          'must be posted, updated, or removed',
        );
    }
    return {'playbackId': record.playbackId, 'broadcastTo': <String>[]};
  }

  Map<String, dynamic> removePlayback(
    String sourceDeviceId,
    String playbackId, {
    String? removedAt,
  }) {
    final key = _key(sourceDeviceId, playbackId);
    final existing = _playbacks[key];
    final removed = MediaPlaybackRecord(
      playbackId: playbackId,
      sourceDeviceId: sourceDeviceId,
      sourcePlatform: existing?.sourcePlatform,
      appId: existing?.appId ?? 'unknown',
      appName: existing?.appName ?? 'Unknown',
      playbackState: existing?.playbackState ?? 'stopped',
      positionMs: existing?.positionMs ?? 0,
      durationMs: existing?.durationMs,
      canPlay: existing?.canPlay ?? false,
      canPause: existing?.canPause ?? false,
      canSkipNext: existing?.canSkipNext ?? false,
      canSkipPrevious: existing?.canSkipPrevious ?? false,
      canSeek: existing?.canSeek ?? false,
      updatedAt:
          existing?.updatedAt ??
          removedAt ??
          DateTime.now().toUtc().toIso8601String(),
      isRemoved: true,
      removedAt: removedAt,
    );
    _playbacks[key] = removed;
    _removedController.add(removed);
    return {'playbackId': playbackId, 'broadcastTo': <String>[]};
  }

  void addActionResult(Map<String, dynamic> event) {
    _actionResultController.add(event);
  }

  String _key(String sourceDeviceId, String playbackId) =>
      '$sourceDeviceId\n$playbackId';
}
