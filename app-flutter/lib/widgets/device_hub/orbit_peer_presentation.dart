import 'package:flutter/material.dart';

enum OrbitPeerActivity {
  none,
  mediaPaused,
  mediaBuffering,
  mediaPlaying,
}

enum OrbitPeerStatusKind {
  trustedOnline,
  trustedOffline,
  nearby,
}

@immutable
class OrbitPeerPowerStatus {
  const OrbitPeerPowerStatus({
    required this.batteryPercent,
    required this.isCharging,
  });

  final int batteryPercent;
  final bool isCharging;
}

@immutable
class OrbitPeerPresentation {
  const OrbitPeerPresentation({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    bool? isOnline,
    OrbitPeerStatusKind? statusKind,
    this.accentColor,
    this.powerStatus,
    this.activity = OrbitPeerActivity.none,
    this.mediaTitle,
    this.mediaArtist,
  })  : assert(isOnline != null || statusKind != null),
        statusKind = statusKind ??
            (isOnline == true
                ? OrbitPeerStatusKind.trustedOnline
                : OrbitPeerStatusKind.trustedOffline);

  final String deviceId;
  final String displayName;
  final String platform;
  final OrbitPeerStatusKind statusKind;
  final Color? accentColor;
  final OrbitPeerPowerStatus? powerStatus;
  final OrbitPeerActivity activity;
  final String? mediaTitle;
  final String? mediaArtist;

  bool get isOnline => statusKind != OrbitPeerStatusKind.trustedOffline;

  String? get statusLabel => switch (statusKind) {
        OrbitPeerStatusKind.trustedOnline => 'Online',
        OrbitPeerStatusKind.trustedOffline => 'Offline',
        OrbitPeerStatusKind.nearby => null,
      };
}
