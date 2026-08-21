import 'package:flutter/material.dart';

const _knownDevicePlatforms = <String>{
  'android',
  'ios',
  'windows',
  'macos',
  'linux',
};

String normalizeDevicePlatform(String? platform) {
  final normalized = platform?.trim().toLowerCase() ?? '';
  return _knownDevicePlatforms.contains(normalized) ? normalized : 'unknown';
}

IconData devicePlatformIcon(String? platform) {
  return switch (normalizeDevicePlatform(platform)) {
    'android' || 'ios' => Icons.smartphone,
    'windows' => Icons.desktop_windows,
    'macos' => Icons.laptop_mac,
    'linux' => Icons.computer,
    _ => Icons.devices,
  };
}

String? devicePlatformLabel(String? platform) {
  return switch (normalizeDevicePlatform(platform)) {
    'android' => 'ANDROID',
    'ios' => 'IOS',
    'windows' => 'WINDOWS',
    'macos' => 'MACOS',
    'linux' => 'LINUX',
    _ => null,
  };
}

String? devicePlatformSemanticLabel(String? platform) {
  return switch (normalizeDevicePlatform(platform)) {
    'android' => 'Android',
    'ios' => 'iOS',
    'windows' => 'Windows',
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => null,
  };
}
