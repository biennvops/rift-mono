import 'package:flutter/material.dart';

import '../../src/media_playback/playback_presentation.dart';
import 'device_platform_presentation.dart';

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
  local,
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
        OrbitPeerStatusKind.nearby => 'Nearby',
        OrbitPeerStatusKind.local => 'This Device',
      };

  String get statusSummaryLabel => statusLabel!;

  String? get powerLabel => powerStatus == null
      ? null
      : '${powerStatus!.batteryPercent}%${powerStatus!.isCharging ? ' · Charging' : ''}';

  String? get mediaStateLabel => switch (activity) {
        OrbitPeerActivity.mediaPlaying => 'Playing',
        OrbitPeerActivity.mediaPaused => 'Paused',
        OrbitPeerActivity.mediaBuffering => 'Buffering',
        OrbitPeerActivity.none => null,
      };

  String semanticDescription({String? role}) {
    final platformLabel = devicePlatformSemanticLabel(platform);
    final power = powerStatus;
    final parts = <String>[
      displayName,
      if (platformLabel != null) platformLabel,
      if (role != null) role,
      switch (statusKind) {
        OrbitPeerStatusKind.trustedOnline => 'online',
        OrbitPeerStatusKind.trustedOffline => 'offline',
        OrbitPeerStatusKind.nearby =>
          role == null ? 'nearby device, ready to pair' : 'ready to pair',
        OrbitPeerStatusKind.local => 'this device',
      },
      if (power != null)
        'battery ${power.batteryPercent} percent${power.isCharging ? ', charging' : ''}',
      if (activity != OrbitPeerActivity.none) _mediaSemanticDescription,
    ];
    return parts.join(', ');
  }

  String get _mediaSemanticDescription => switch (activity) {
        OrbitPeerActivity.mediaPlaying =>
          'playing ${mediaTitle ?? 'media'}${mediaArtist == null ? '' : ' by $mediaArtist'}',
        OrbitPeerActivity.mediaPaused => '${mediaTitle ?? 'media'} paused',
        OrbitPeerActivity.mediaBuffering =>
          'buffering ${mediaTitle ?? 'media'}',
        OrbitPeerActivity.none => '',
      };
}

OrbitPeerPresentation buildTrustedDevicePresentation({
  required Map<String, dynamic> peer,
  Map<String, dynamic>? deviceStatus,
  MediaPlaybackPresentation? mediaPlayback,
  bool? isOnline,
}) {
  final online =
      isOnline ?? peer['presence']?.toString().trim().toLowerCase() == 'online';
  return _buildDevicePresentation(
    peer: peer,
    statusKind: online
        ? OrbitPeerStatusKind.trustedOnline
        : OrbitPeerStatusKind.trustedOffline,
    deviceStatus: deviceStatus ?? _deviceStatusFrom(peer),
    mediaPlayback: mediaPlayback,
    includeLiveState: online,
  );
}

OrbitPeerPresentation buildNearbyDevicePresentation(
  Map<String, dynamic> peer,
) {
  return _buildDevicePresentation(
    peer: peer,
    statusKind: OrbitPeerStatusKind.nearby,
    includeLiveState: false,
  );
}

OrbitPeerPresentation buildLocalDevicePresentation({
  required Map<String, dynamic> device,
  Map<String, dynamic>? deviceStatus,
  MediaPlaybackPresentation? mediaPlayback,
}) {
  return _buildDevicePresentation(
    peer: device,
    statusKind: OrbitPeerStatusKind.local,
    deviceStatus: deviceStatus ?? _deviceStatusFrom(device),
    mediaPlayback: mediaPlayback,
    includeLiveState: true,
  );
}

String resolveDeviceDisplayName(Map<String, dynamic> device) {
  final displayName = device['displayName']?.toString().trim() ?? '';
  if (displayName.isNotEmpty) return displayName;

  final deviceId = device['deviceId']?.toString().trim() ?? '';
  return deviceId.isNotEmpty ? deviceId : 'Unknown device';
}

OrbitPeerPresentation _buildDevicePresentation({
  required Map<String, dynamic> peer,
  required OrbitPeerStatusKind statusKind,
  required bool includeLiveState,
  Map<String, dynamic>? deviceStatus,
  MediaPlaybackPresentation? mediaPlayback,
}) {
  final powerStatus =
      includeLiveState ? _resolvePowerStatus(deviceStatus) : null;
  final activity = includeLiveState
      ? _resolveMediaActivity(mediaPlayback?.playbackState)
      : OrbitPeerActivity.none;
  final hasLiveMedia = activity != OrbitPeerActivity.none;
  final title = mediaPlayback?.title.trim() ?? '';
  final artist = mediaPlayback?.artist.trim() ?? '';

  return OrbitPeerPresentation(
    deviceId: peer['deviceId']?.toString().trim() ?? '',
    displayName: resolveDeviceDisplayName(peer),
    platform: normalizeDevicePlatform(peer['platform']?.toString()),
    statusKind: statusKind,
    accentColor: hasLiveMedia ? mediaPlayback?.accentColor : null,
    powerStatus: powerStatus,
    activity: activity,
    mediaTitle: hasLiveMedia && title.isNotEmpty ? title : null,
    mediaArtist: hasLiveMedia && artist.isNotEmpty ? artist : null,
  );
}

Map<String, dynamic>? _deviceStatusFrom(Map<String, dynamic> peer) {
  final status = peer['deviceStatus'];
  return status is Map ? Map<String, dynamic>.from(status) : null;
}

OrbitPeerPowerStatus? _resolvePowerStatus(
  Map<String, dynamic>? deviceStatus,
) {
  final batteryPercent = deviceStatus?['batteryPercent'];
  if (deviceStatus == null ||
      deviceStatus['isStale'] == true ||
      deviceStatus['batteryPresent'] == false ||
      batteryPercent is! num) {
    return null;
  }

  return OrbitPeerPowerStatus(
    batteryPercent: batteryPercent.toInt().clamp(0, 100).toInt(),
    isCharging:
        deviceStatus['chargingState']?.toString().trim().toLowerCase() ==
            'charging',
  );
}

OrbitPeerActivity _resolveMediaActivity(String? playbackState) {
  return switch (playbackState?.trim().toLowerCase()) {
    'playing' => OrbitPeerActivity.mediaPlaying,
    'paused' => OrbitPeerActivity.mediaPaused,
    'buffering' => OrbitPeerActivity.mediaBuffering,
    _ => OrbitPeerActivity.none,
  };
}
