class MediaPlaybackRecord {
  final String playbackId;
  final String sourceDeviceId;
  final String? sourcePlatform;
  final String appId;
  final String appName;
  final String? title;
  final String? artist;
  final String? album;
  final Map<String, dynamic>? artwork;
  final bool artworkPending;
  final String playbackState;
  final int positionMs;
  final int? durationMs;
  final bool canPlay;
  final bool canPause;
  final bool canSkipNext;
  final bool canSkipPrevious;
  final bool canSeek;
  final String updatedAt;
  final bool isRemoved;
  final String? removedAt;

  const MediaPlaybackRecord({
    required this.playbackId,
    required this.sourceDeviceId,
    this.sourcePlatform,
    required this.appId,
    required this.appName,
    this.title,
    this.artist,
    this.album,
    this.artwork,
    this.artworkPending = false,
    required this.playbackState,
    required this.positionMs,
    this.durationMs,
    required this.canPlay,
    required this.canPause,
    required this.canSkipNext,
    required this.canSkipPrevious,
    required this.canSeek,
    required this.updatedAt,
    this.isRemoved = false,
    this.removedAt,
  });

  Map<String, dynamic> toJson() => {
    'playbackId': playbackId,
    'sourceDeviceId': sourceDeviceId,
    if (sourcePlatform != null) 'sourcePlatform': sourcePlatform,
    'appId': appId,
    'appName': appName,
    if (title != null) 'title': title,
    if (artist != null) 'artist': artist,
    if (album != null) 'album': album,
    if (artwork != null) 'artwork': artwork,
    if (artworkPending) 'artworkPending': true,
    'playbackState': playbackState,
    'positionMs': positionMs,
    if (durationMs != null) 'durationMs': durationMs,
    'canPlay': canPlay,
    'canPause': canPause,
    'canSkipNext': canSkipNext,
    'canSkipPrevious': canSkipPrevious,
    'canSeek': canSeek,
    'updatedAt': updatedAt,
    if (isRemoved) 'isRemoved': true,
    if (removedAt != null) 'removedAt': removedAt,
  };
}
