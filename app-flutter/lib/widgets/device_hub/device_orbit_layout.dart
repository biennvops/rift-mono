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
  static const double _horizontalMargin = 28;
  static const double _verticalMargin = 24;
  static const double _coreGap = 12;
  static const double _peerGap = 10;

  static DeviceOrbitGeometry calculate(
    Size size, {
    int peerCount = 0,
  }) {
    final shortestSide = math.min(size.width, size.height);
    final nominalLocalCoreSize =
        (shortestSide * 0.24).clamp(126.0, 174.0).toDouble();
    final nominalPeerSize =
        (shortestSide * 0.17).clamp(102.0, 126.0).toDouble();
    final coreClearance =
        (nominalLocalCoreSize + nominalPeerSize) / 2 + _coreGap;
    final peerClearance = peerCount <= 1
        ? 0.0
        : (nominalPeerSize + _peerGap) / (2 * math.sin(math.pi / peerCount));
    final requiredRadius = math.max(coreClearance, peerClearance);
    final radiusAndPeerExtent = requiredRadius + nominalPeerSize / 2;
    final widthScale =
        math.max(0.0, size.width / 2 - _horizontalMargin) / radiusAndPeerExtent;
    final heightScale =
        math.max(0.0, size.height / 2 - _verticalMargin) / radiusAndPeerExtent;
    final localWidthScale = math.max(0.0, size.width) / nominalLocalCoreSize;
    final localHeightScale = math.max(0.0, size.height) / nominalLocalCoreSize;
    final scale = peerCount <= 0
        ? math.min(1.0, math.min(localWidthScale, localHeightScale))
        : math.min(
            1.0,
            math.min(
              math.min(widthScale, heightScale),
              math.min(localWidthScale, localHeightScale),
            ),
          );
    final localCoreSize = nominalLocalCoreSize * scale;
    final peerSize = nominalPeerSize * scale;
    final minimumRadius = requiredRadius * scale;
    final horizontalRoom =
        math.max(0.0, (size.width - peerSize) / 2 - _horizontalMargin);
    final verticalRoom =
        math.max(0.0, (size.height - peerSize) / 2 - _verticalMargin);

    return DeviceOrbitGeometry(
      center: Offset(size.width / 2, size.height / 2),
      radiusX: math.min(
        horizontalRoom,
        math.max(size.width * 0.36, minimumRadius),
      ),
      radiusY: math.min(
        verticalRoom,
        math.max(size.height * 0.33, minimumRadius),
      ),
      localCoreSize: localCoreSize,
      peerSize: peerSize,
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
