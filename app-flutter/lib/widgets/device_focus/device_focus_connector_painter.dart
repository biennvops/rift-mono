import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'device_focus_layout.dart';

class DeviceFocusConnectorPainter extends CustomPainter {
  DeviceFocusConnectorPainter({
    required this.geometry,
    required this.entrance,
    required this.online,
    required this.color,
    required this.activeNode,
    required this.hoveredNode,
  }) : super(repaint: Listenable.merge([entrance, online]));

  final DeviceFocusGeometry geometry;
  final Animation<double> entrance;
  final Animation<double> online;
  final Color color;
  final DeviceFocusNodeKind? activeNode;
  final DeviceFocusNodeKind? hoveredNode;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = Curves.easeOutCubic.transform(
      ((entrance.value - 0.42) / 0.48).clamp(0.0, 1.0).toDouble(),
    );
    if (progress == 0) return;

    final coreRadius = geometry.coreSize / 2 + 8;
    final nodeRadius = math.min(
          geometry.nodeSize.width,
          geometry.nodeSize.height,
        ) /
        2;

    for (final entry in geometry.nodeCenters.entries) {
      final vector = entry.value - geometry.center;
      final distance = vector.distance;
      if (distance <= coreRadius + nodeRadius) continue;

      final direction = vector / distance;
      final start = geometry.center + direction * coreRadius;
      final end = entry.value - direction * (nodeRadius + 3);
      final midpoint = Offset.lerp(start, end, 0.5)!;
      final normal = Offset(-direction.dy, direction.dx);
      final bend = entry.key.index.isEven ? 8.0 : -8.0;
      final control = midpoint + normal * bend;
      final highlighted = entry.key == hoveredNode || entry.key == activeNode;
      final baseAlpha = 0.09 + online.value * 0.12;
      final alpha = progress * (highlighted ? baseAlpha + 0.18 : baseAlpha);

      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
      if (highlighted) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: alpha * 0.18),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = highlighted ? 1.8 : 1.1
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(DeviceFocusConnectorPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.color != color ||
        oldDelegate.activeNode != activeNode ||
        oldDelegate.hoveredNode != hoveredNode;
  }
}
