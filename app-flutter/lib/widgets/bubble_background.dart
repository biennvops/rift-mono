import 'dart:math' as math;
import 'package:flutter/material.dart';

class BubbleBackground extends StatelessWidget {
  final double progress;
  final Color color;

  const BubbleBackground({
    super.key,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BubblePainter(
        progress: progress,
        color: color,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _BubblePainter extends CustomPainter {
  final double progress;
  final Color color;

  static const int _count = 12;
  static final List<_Bubble> _bubbles = List.generate(_count, (i) {
    final rng = math.Random(i * 37 + 7);
    return _Bubble(
      x: rng.nextDouble(),
      radius: 2.0 + rng.nextDouble() * 4.0,
      speed: 0.6 + rng.nextDouble() * 0.4,
      phase: rng.nextDouble(),
      wobble: 0.01 + rng.nextDouble() * 0.02,
      opacity: 0.06 + rng.nextDouble() * 0.10,
    );
  });

  _BubblePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in _bubbles) {
      final t = (progress * b.speed + b.phase) % 1.0;
      final y = size.height * (1.0 - t);
      final x =
          size.width * b.x + math.sin(t * math.pi * 4) * size.width * b.wobble;
      final fade = t < 0.15 ? t / 0.15 : (t > 0.85 ? (1.0 - t) / 0.15 : 1.0);
      final paint = Paint()..color = color.withValues(alpha: b.opacity * fade);
      canvas.drawCircle(Offset(x, y), b.radius, paint);
    }
  }

  @override
  bool shouldRepaint(_BubblePainter old) => old.progress != progress;
}

class _Bubble {
  final double x;
  final double radius;
  final double speed;
  final double phase;
  final double wobble;
  final double opacity;

  const _Bubble({
    required this.x,
    required this.radius,
    required this.speed,
    required this.phase,
    required this.wobble,
    required this.opacity,
  });
}
