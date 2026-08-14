import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

class MediaPlaybackActivityRing extends StatefulWidget {
  const MediaPlaybackActivityRing({
    super.key,
    required this.size,
    required this.color,
    required this.isPlaying,
  });

  final double size;
  final Color color;
  final bool isPlaying;

  @override
  State<MediaPlaybackActivityRing> createState() =>
      _MediaPlaybackActivityRingState();
}

class _MediaPlaybackActivityRingState extends State<MediaPlaybackActivityRing>
    with SingleTickerProviderStateMixin {
  static const bool _isFlutterTest = bool.fromEnvironment('FLUTTER_TEST');
  static final bool _enableContinuousAnimation =
      !_isFlutterTest && !Platform.environment.containsKey('FLUTTER_TEST');
  late final AnimationController _controller;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(MediaPlaybackActivityRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _syncAnimation();
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.isPlaying && !_reducedMotion && _enableContinuousAnimation;
    if (shouldAnimate) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      if (!widget.isPlaying) _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isPlaying) return SizedBox.square(dimension: widget.size);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _MediaPlaybackActivityRingPainter(
              color: widget.color,
              phase: _controller.value,
            ),
          );
        },
      ),
    );
  }
}

class _MediaPlaybackActivityRingPainter extends CustomPainter {
  const _MediaPlaybackActivityRingPainter({
    required this.color,
    required this.phase,
  });

  final Color color;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ringRect = rect.deflate(3);
    canvas.drawArc(
      ringRect,
      phase * math.pi * 2 - math.pi / 2,
      math.pi * 0.58,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.78),
    );
    canvas.drawArc(
      ringRect,
      phase * math.pi * 2 + math.pi * 0.55,
      math.pi * 0.24,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.12),
    );
  }

  @override
  bool shouldRepaint(_MediaPlaybackActivityRingPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.phase != phase;
  }
}
