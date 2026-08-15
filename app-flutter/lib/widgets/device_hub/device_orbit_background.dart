import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'device_orbit_layout.dart';

class DeviceOrbitBackground extends StatelessWidget {
  const DeviceOrbitBackground({
    super.key,
    required this.geometry,
    required this.scanning,
    required this.scanProgress,
  });

  final DeviceOrbitGeometry geometry;
  final bool scanning;
  final Animation<double> scanProgress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _DeviceOrbitBackgroundPainter(
          geometry: geometry,
          scanning: scanning,
          scanProgress: scanProgress,
          primary: colors.primary,
          secondary: colors.secondary,
          outline: colors.outlineVariant,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _DeviceOrbitBackgroundPainter extends CustomPainter {
  _DeviceOrbitBackgroundPainter({
    required this.geometry,
    required this.scanning,
    required this.scanProgress,
    required this.primary,
    required this.secondary,
    required this.outline,
  }) : super(repaint: scanning ? scanProgress : null);

  final DeviceOrbitGeometry geometry;
  final bool scanning;
  final Animation<double> scanProgress;
  final Color primary;
  final Color secondary;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    final washRadius = math.max(size.width, size.height) * 0.48;
    final washPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primary.withValues(alpha: scanning ? 0.07 : 0.045),
          primary.withValues(alpha: 0),
        ],
      ).createShader(
        Rect.fromCircle(center: geometry.center, radius: washRadius),
      );
    canvas.drawCircle(geometry.center, washRadius, washPaint);

    final orbitRect = Rect.fromCenter(
      center: geometry.center,
      width: geometry.radiusX * 2,
      height: geometry.radiusY * 2,
    );
    canvas.drawOval(
      orbitRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = outline.withValues(alpha: 0.7),
    );
    canvas.drawOval(
      orbitRect.inflate(12),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = secondary.withValues(alpha: 0.08),
    );

    if (!scanning) return;
    final progress = Curves.easeInOut.transform(scanProgress.value);
    for (var index = 0; index < 3; index++) {
      final normalized = (progress + index / 3) % 1;
      final radius = geometry.localCoreSize / 2 + 24 + normalized * 92;
      canvas.drawCircle(
        geometry.center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = primary.withValues(alpha: (1 - normalized) * 0.16),
      );
    }
  }

  @override
  bool shouldRepaint(_DeviceOrbitBackgroundPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.scanning != scanning ||
        oldDelegate.primary != primary ||
        oldDelegate.secondary != secondary ||
        oldDelegate.outline != outline;
  }
}
