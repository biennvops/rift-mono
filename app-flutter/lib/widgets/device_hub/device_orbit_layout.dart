import 'dart:math' as math;

import 'package:flutter/material.dart';

@immutable
class DeviceOrbitGeometry {
  const DeviceOrbitGeometry({
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.localCoreSize,
    required this.peerSize,
  });

  final Offset center;
  final double radiusX;
  final double radiusY;
  final double localCoreSize;
  final double peerSize;
}

abstract final class DeviceOrbitLayout {
  static DeviceOrbitGeometry calculate(Size size) {
    final shortestSide = math.min(size.width, size.height);
    final localCoreSize = (shortestSide * 0.24).clamp(126.0, 174.0);
    final peerSize = (shortestSide * 0.17).clamp(102.0, 126.0);
    final horizontalRoom = math.max(0.0, (size.width - peerSize) / 2 - 28);
    final verticalRoom = math.max(0.0, (size.height - peerSize) / 2 - 24);

    return DeviceOrbitGeometry(
      center: Offset(size.width / 2, size.height / 2),
      radiusX: math.min(size.width * 0.36, horizontalRoom),
      radiusY: math.min(size.height * 0.33, verticalRoom),
      localCoreSize: localCoreSize.toDouble(),
      peerSize: peerSize.toDouble(),
    );
  }

  static Offset peerCenter({
    required DeviceOrbitGeometry geometry,
    required int index,
    required int peerCount,
    required double phase,
  }) {
    if (peerCount <= 0) return geometry.center;
    final angle =
        phase * math.pi * 2 - math.pi / 2 + index * math.pi * 2 / peerCount;
    return geometry.center +
        Offset(
          math.cos(angle) * geometry.radiusX,
          math.sin(angle) * geometry.radiusY,
        );
  }
}
