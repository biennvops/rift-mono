import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'device_focus_layout.dart';

class DeviceFocusBackground extends StatelessWidget {
  const DeviceFocusBackground({
    super.key,
    required this.geometry,
    required this.entrance,
    required this.online,
    required this.ambient,
  });

  final DeviceFocusGeometry geometry;
  final Animation<double> entrance;
  final Animation<double> online;
  final Animation<double> ambient;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _DeviceFocusBackgroundPainter(
          geometry: geometry,
          entrance: entrance,
          online: online,
          ambient: ambient,
          primary: colors.primary,
          secondary: colors.secondary,
          outline: colors.outlineVariant,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _DeviceFocusBackgroundPainter extends CustomPainter {
  _DeviceFocusBackgroundPainter({
    required this.geometry,
    required this.entrance,
    required this.online,
    required this.ambient,
    required this.primary,
    required this.secondary,
    required this.outline,
  }) : super(repaint: Listenable.merge([entrance, online, ambient]));

  final DeviceFocusGeometry geometry;
  final Animation<double> entrance;
  final Animation<double> online;
  final Animation<double> ambient;
  final Color primary;
  final Color secondary;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    final sceneProgress = Curves.easeOutCubic.transform(entrance.value);
    final ringProgress = Curves.easeOutQuart.transform(
      ((entrance.value - 0.18) / 0.44).clamp(0.0, 1.0).toDouble(),
    );
    final onlineStrength = online.value;
    final phase = ambient.value * math.pi * 2;

    final washRadius = math.max(size.width, size.height) * 0.48;
    final washCenter = geometry.center +
        Offset(
          math.cos(phase) * size.width * 0.025,
          math.sin(phase) * size.height * 0.018,
        );
    final washPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primary.withValues(
            alpha: sceneProgress * (0.035 + onlineStrength * 0.035),
          ),
          primary.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: washCenter, radius: washRadius));
    canvas.drawCircle(washCenter, washRadius, washPaint);

    final orbitalPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = secondary.withValues(alpha: sceneProgress * 0.07);
    canvas.save();
    canvas.translate(geometry.center.dx, geometry.center.dy);
    canvas.rotate(math.sin(phase) * 0.035 - 0.14);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: math.min(size.width * 0.88, 720),
        height: math.min(size.height * 0.58, 480),
      ),
      orbitalPaint,
    );
    canvas.rotate(0.31);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: math.min(size.width * 0.72, 580),
        height: math.min(size.height * 0.76, 620),
      ),
      orbitalPaint..color = primary.withValues(alpha: sceneProgress * 0.045),
    );
    canvas.restore();

    final coreRadius = geometry.coreSize / 2;
    for (var index = 0; index < 3; index++) {
      final radius = coreRadius + 24 + index * 28;
      final scale = 0.9 + ringProgress * 0.1;
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = index == 0 ? 1.4 : 1
        ..color = Color.lerp(outline, primary, onlineStrength)!.withValues(
          alpha: ringProgress * (0.11 - index * 0.018),
        );
      canvas.drawCircle(geometry.center, radius * scale, ringPaint);
    }

    final markerPaint = Paint()
      ..color = primary.withValues(
        alpha: ringProgress * (0.08 + onlineStrength * 0.05),
      );
    for (var index = 0; index < 6; index++) {
      final angle = phase * 0.05 + index * math.pi / 3;
      final radius = coreRadius + 80;
      canvas.drawCircle(
        geometry.center + Offset(math.cos(angle), math.sin(angle)) * radius,
        2,
        markerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_DeviceFocusBackgroundPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.primary != primary ||
        oldDelegate.secondary != secondary ||
        oldDelegate.outline != outline;
  }
}
