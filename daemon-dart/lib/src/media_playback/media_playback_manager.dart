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
        final removed = MediaPlaybackRecord(
          playbackId: record.playbackId,
          sourceDeviceId: record.sourceDeviceId,
          sourcePlatform: record.sourcePlatform,
          appId: record.appId,
          appName: record.appName,
          playbackState: record.playbackState,
          positionMs: record.positionMs,
          durationMs: record.durationMs,
          canPlay: record.canPlay,
          canPause: record.canPause,
          canSkipNext: record.canSkipNext,
          canSkipPrevious: record.canSkipPrevious,
          canSeek: record.canSeek,
          updatedAt: record.updatedAt,
          isRemoved: true,
          removedAt: record.removedAt,
        );
        _playbacks[key] = removed;
        _removedController.add(removed);
        break;
    }
    return {'playbackId': record.playbackId, 'broadcastTo': <String>[]};
  }

  void addActionResult(Map<String, dynamic> event) {
    _actionResultController.add(event);
  }

  String _key(String sourceDeviceId, String playbackId) =>
      '$sourceDeviceId\n$playbackId';
}
