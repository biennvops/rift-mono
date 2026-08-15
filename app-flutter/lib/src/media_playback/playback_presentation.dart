import 'dart:typed_data';

import 'package:flutter/material.dart';

String? mediaPlaybackKey(Map<String, dynamic> playback) {
  final sourceDeviceId = playback['sourceDeviceId']?.toString();
  final playbackId = playback['playbackId']?.toString();
  if (sourceDeviceId == null ||
      sourceDeviceId.isEmpty ||
      playbackId == null ||
      playbackId.isEmpty) {
    return null;
  }
  return '$sourceDeviceId:$playbackId';
}

Map<String, dynamic>? selectCurrentPlaybackForDevice(
  Iterable<Map<String, dynamic>> playbacks,
  String deviceId,
) {
  final candidates = playbacks
      .where((playback) =>
          playback['sourceDeviceId']?.toString() == deviceId &&
          playback['playbackState']?.toString() != 'stopped')
      .toList(growable: false)
    ..sort(_compareNewestPlayback);
  return candidates.isEmpty ? null : candidates.first;
}

int _compareNewestPlayback(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftUpdated =
      DateTime.tryParse(left['updatedAt']?.toString() ?? '')?.toUtc();
  final rightUpdated =
      DateTime.tryParse(right['updatedAt']?.toString() ?? '')?.toUtc();
  if (leftUpdated != null && rightUpdated != null) {
    final timestampOrder = rightUpdated.compareTo(leftUpdated);
    if (timestampOrder != 0) return timestampOrder;
  } else if (leftUpdated == null && rightUpdated != null) {
    return 1;
  } else if (leftUpdated != null && rightUpdated == null) {
    return -1;
  }

  final leftId = left['playbackId']?.toString() ?? '';
  final rightId = right['playbackId']?.toString() ?? '';
  return leftId.compareTo(rightId);
}

@immutable
class MediaPlaybackPresentation {
  const MediaPlaybackPresentation({
    required this.playbackId,
    required this.sourceDeviceId,
    required this.application,
    required this.title,
    required this.artist,
    required this.album,
    required this.playbackState,
    required this.positionMs,
    required this.durationMs,
    this.artworkBytes,
    this.artworkIdentity,
    this.accentColor,
  });

  factory MediaPlaybackPresentation.fromRecord(
    Map<String, dynamic> playback, {
    Uint8List? artworkBytes,
    String? artworkIdentity,
    Color? accentColor,
  }) {
    return MediaPlaybackPresentation(
      playbackId: playback['playbackId']?.toString() ?? '',
      sourceDeviceId: playback['sourceDeviceId']?.toString() ?? '',
      application: playback['appName']?.toString() ?? '',
      title: playback['title']?.toString() ?? '',
      artist: playback['artist']?.toString() ?? '',
      album: playback['album']?.toString() ?? '',
      playbackState: playback['playbackState']?.toString() ?? 'paused',
      positionMs: (playback['positionMs'] as num?)?.toInt(),
      durationMs: (playback['durationMs'] as num?)?.toInt(),
      artworkBytes: artworkBytes,
      artworkIdentity: artworkIdentity,
      accentColor: accentColor,
    );
  }

  final String playbackId;
  final String sourceDeviceId;
  final String application;
  final String title;
  final String artist;
  final String album;
  final String playbackState;
  final int? positionMs;
  final int? durationMs;
  final Uint8List? artworkBytes;
  final String? artworkIdentity;
  final Color? accentColor;

  bool get isPlaying => playbackState == 'playing';
  bool get isPaused => playbackState == 'paused';

  String get displayTitle => title.isNotEmpty
      ? title
      : (application.isNotEmpty ? application : 'Unknown media');

  String get stateLabel => switch (playbackState) {
        'playing' => 'Playing',
        'paused' => 'Paused',
        'buffering' => 'Buffering',
        _ => 'Media',
      };
}
