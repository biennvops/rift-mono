import 'package:flutter/material.dart';

enum OrbitPeerActivity {
  none,
  mediaPaused,
  mediaPlaying,
}

@immutable
class OrbitPeerPresentation {
  const OrbitPeerPresentation({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.isOnline,
    this.accentColor,
    this.activity = OrbitPeerActivity.none,
    this.mediaTitle,
    this.mediaArtist,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final bool isOnline;
  final Color? accentColor;
  final OrbitPeerActivity activity;
  final String? mediaTitle;
  final String? mediaArtist;
}
