import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/media_playback/playback_presentation.dart';
import 'package:rift/widgets/device_hub/device_platform_presentation.dart';
import 'package:rift/widgets/device_hub/orbit_peer_presentation.dart';

Map<String, dynamic> peer({
  String? displayName = 'Pixel 9',
  String platform = 'android',
  String presence = 'online',
}) {
  return {
    'deviceId': 'rift-pixel',
    if (displayName != null) 'displayName': displayName,
    'platform': platform,
    'presence': presence,
  };
}

MediaPlaybackPresentation media({
  String state = 'playing',
  String title = 'Example Track',
  String artist = 'Example Artist',
  Color? accentColor,
}) {
  return MediaPlaybackPresentation(
    playbackId: 'playback-1',
    sourceDeviceId: 'rift-pixel',
    application: 'Player',
    title: title,
    artist: artist,
    album: '',
    playbackState: state,
    positionMs: null,
    durationMs: null,
    accentColor: accentColor,
  );
}

void main() {
  group('device role presentation', () {
    test('resolves trusted online and offline presence', () {
      final online = buildTrustedDevicePresentation(peer: peer());
      final offline = buildTrustedDevicePresentation(
        peer: peer(presence: ' OFFLINE '),
      );

      expect(online.statusKind, OrbitPeerStatusKind.trustedOnline);
      expect(online.statusLabel, 'Online');
      expect(offline.statusKind, OrbitPeerStatusKind.trustedOffline);
      expect(offline.statusLabel, 'Offline');
    });

    test('resolves nearby and local roles without faking remote presence', () {
      final nearby = buildNearbyDevicePresentation(peer());
      final local = buildLocalDevicePresentation(device: peer());

      expect(nearby.statusKind, OrbitPeerStatusKind.nearby);
      expect(nearby.statusLabel, 'Nearby');
      expect(local.statusKind, OrbitPeerStatusKind.local);
      expect(local.statusLabel, 'This Device');
    });

    test('uses one trimmed display-name fallback chain', () {
      expect(
        buildNearbyDevicePresentation(
          peer(displayName: '  Pixel 9  '),
        ).displayName,
        'Pixel 9',
      );
      expect(
        buildNearbyDevicePresentation(peer(displayName: '   ')).displayName,
        'rift-pixel',
      );
      expect(
        buildNearbyDevicePresentation({
          'displayName': '',
          'deviceId': ' ',
        }).displayName,
        'Unknown device',
      );
    });
  });

  group('live power presentation', () {
    test('shows fresh online battery and charging state', () {
      final battery = buildTrustedDevicePresentation(
        peer: peer(),
        deviceStatus: {
          'batteryPercent': 82,
          'chargingState': 'discharging',
          'isStale': false,
        },
      );
      final charging = buildTrustedDevicePresentation(
        peer: peer(),
        deviceStatus: {
          'batteryPercent': 82,
          'chargingState': ' Charging ',
          'isStale': false,
        },
      );

      expect(battery.powerStatus?.batteryPercent, 82);
      expect(battery.powerStatus?.isCharging, isFalse);
      expect(battery.powerLabel, '82%');
      expect(charging.powerStatus?.isCharging, isTrue);
      expect(charging.powerLabel, '82% · Charging');
    });

    test('does not invent unavailable battery telemetry', () {
      final noBatteryValue = buildTrustedDevicePresentation(
        peer: peer(),
        deviceStatus: {'chargingState': 'charging', 'isStale': false},
      );
      final batteryAbsent = buildTrustedDevicePresentation(
        peer: peer(),
        deviceStatus: {
          'batteryPresent': false,
          'batteryPercent': 75,
          'isStale': false,
        },
      );

      expect(noBatteryValue.powerStatus, isNull);
      expect(noBatteryValue.statusLabel, 'Online');
      expect(batteryAbsent.powerStatus, isNull);
    });

    test('suppresses cached offline and stale battery telemetry', () {
      final status = {
        'batteryPresent': true,
        'batteryPercent': 75,
        'isStale': false,
      };
      final offline = buildTrustedDevicePresentation(
        peer: peer(presence: 'offline'),
        deviceStatus: status,
      );
      final stale = buildTrustedDevicePresentation(
        peer: peer(),
        deviceStatus: {...status, 'isStale': true},
      );

      expect(offline.powerStatus, isNull);
      expect(stale.powerStatus, isNull);
    });

    test('clamps battery percentages', () {
      final belowRange = buildTrustedDevicePresentation(
        peer: peer(),
        deviceStatus: {'batteryPercent': -4},
      );
      final aboveRange = buildTrustedDevicePresentation(
        peer: peer(),
        deviceStatus: {'batteryPercent': 140},
      );

      expect(belowRange.powerStatus?.batteryPercent, 0);
      expect(aboveRange.powerStatus?.batteryPercent, 100);
    });
  });

  group('platform presentation', () {
    test('normalizes known platforms', () {
      expect(normalizeDevicePlatform('android'), 'android');
      expect(normalizeDevicePlatform('ios'), 'ios');
      expect(normalizeDevicePlatform('windows'), 'windows');
      expect(normalizeDevicePlatform('macos'), 'macos');
      expect(normalizeDevicePlatform('linux'), 'linux');
      expect(normalizeDevicePlatform('  AnDrOiD  '), 'android');
    });

    test('uses generic presentation for unknown and empty platforms', () {
      expect(normalizeDevicePlatform('plan9'), 'unknown');
      expect(normalizeDevicePlatform(''), 'unknown');
      expect(normalizeDevicePlatform(null), 'unknown');
      expect(devicePlatformIcon('plan9'), Icons.devices);
      expect(devicePlatformLabel('plan9'), isNull);
    });

    test('maps every known platform to its canonical icon and label', () {
      expect(devicePlatformIcon('android'), Icons.smartphone);
      expect(devicePlatformIcon('ios'), Icons.smartphone);
      expect(devicePlatformIcon('windows'), Icons.desktop_windows);
      expect(devicePlatformIcon('macos'), Icons.laptop_mac);
      expect(devicePlatformIcon('linux'), Icons.computer);
      expect(devicePlatformLabel(' ANDROID '), 'ANDROID');
      expect(devicePlatformLabel('ios'), 'IOS');
      expect(devicePlatformLabel('windows'), 'WINDOWS');
      expect(devicePlatformLabel('macos'), 'MACOS');
      expect(devicePlatformLabel('linux'), 'LINUX');
    });
  });

  group('live media presentation', () {
    test('resolves playing, paused, buffering, and none', () {
      expect(
        buildTrustedDevicePresentation(
          peer: peer(),
          mediaPlayback: media(state: 'playing'),
        ).activity,
        OrbitPeerActivity.mediaPlaying,
      );
      expect(
        buildTrustedDevicePresentation(
          peer: peer(),
          mediaPlayback: media(state: 'paused'),
        ).activity,
        OrbitPeerActivity.mediaPaused,
      );
      expect(
        buildTrustedDevicePresentation(
          peer: peer(),
          mediaPlayback: media(state: 'buffering'),
        ).activity,
        OrbitPeerActivity.mediaBuffering,
      );
      expect(
        buildTrustedDevicePresentation(peer: peer()).activity,
        OrbitPeerActivity.none,
      );
      expect(
        buildTrustedDevicePresentation(
          peer: peer(),
          mediaPlayback: media(state: 'stopped'),
        ).activity,
        OrbitPeerActivity.none,
      );
    });

    test('keeps media metadata optional', () {
      final missingTitle = buildTrustedDevicePresentation(
        peer: peer(),
        mediaPlayback: media(title: ''),
      );
      final missingArtist = buildTrustedDevicePresentation(
        peer: peer(),
        mediaPlayback: media(artist: ''),
      );

      expect(missingTitle.mediaTitle, isNull);
      expect(missingTitle.mediaArtist, 'Example Artist');
      expect(missingArtist.mediaTitle, 'Example Track');
      expect(missingArtist.mediaArtist, isNull);
    });

    test('uses media accent only for a current live media state', () {
      const accent = Color(0xFF123456);
      final accented = buildTrustedDevicePresentation(
        peer: peer(),
        mediaPlayback: media(accentColor: accent),
      );
      final withoutAccent = buildTrustedDevicePresentation(
        peer: peer(),
        mediaPlayback: media(),
      );
      final offline = buildTrustedDevicePresentation(
        peer: peer(presence: 'offline'),
        mediaPlayback: media(accentColor: accent),
      );

      expect(accented.accentColor, accent);
      expect(withoutAccent.accentColor, isNull);
      expect(offline.accentColor, isNull);
      expect(offline.activity, OrbitPeerActivity.none);
      expect(offline.mediaTitle, isNull);
      expect(offline.mediaArtist, isNull);
    });
  });
}
