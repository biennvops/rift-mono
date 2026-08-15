import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/ui/motion.dart';

enum MediaPlaybackActivityKind {
  playing,
  buffering,
}

class MediaPlaybackActivityIndicator extends StatefulWidget {
  const MediaPlaybackActivityIndicator({
    super.key,
    required this.size,
    required this.color,
    required this.kind,
  });

  final double size;
  final Color color;
  final MediaPlaybackActivityKind kind;

  @override
  State<MediaPlaybackActivityIndicator> createState() =>
      _MediaPlaybackActivityIndicatorState();
}

class _MediaPlaybackActivityIndicatorState
    extends State<MediaPlaybackActivityIndicator>
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
      duration: _durationFor(widget.kind),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = RiftMotion.reducedMotionOf(context);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(MediaPlaybackActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _controller.duration = _durationFor(widget.kind);
      _controller.value = 0;
    }
    _syncAnimation();
  }

  Duration _durationFor(MediaPlaybackActivityKind kind) => switch (kind) {
        MediaPlaybackActivityKind.playing => const Duration(milliseconds: 1600),
        MediaPlaybackActivityKind.buffering =>
          const Duration(milliseconds: 1800),
      };

  void _syncAnimation() {
    if (!_reducedMotion && _enableContinuousAnimation) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            key: ValueKey('media-activity-${widget.kind.name}'),
            size: Size.square(widget.size),
            painter: _MediaPlaybackActivityPainter(
              color: widget.color,
              kind: widget.kind,
              phase: _reducedMotion ? 0.18 : _controller.value,
            ),
          );
        },
      ),
    );
  }
}

class _MediaPlaybackActivityPainter extends CustomPainter {
  const _MediaPlaybackActivityPainter({
    required this.color,
    required this.kind,
    required this.phase,
  });

  final Color color;
  final MediaPlaybackActivityKind kind;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case MediaPlaybackActivityKind.playing:
        _paintEqualizer(canvas, size);
        return;
      case MediaPlaybackActivityKind.buffering:
        _paintBufferingArc(canvas, size);
        return;
    }
  }

  void _paintEqualizer(Canvas canvas, Size size) {
    const barCount = 5;
    final centerX = size.width / 2;
    final spacing = size.width * 0.075;
    final baseY = size.height * 0.94;
    final minHeight = math.max(2.5, size.height * 0.045);
    final amplitude = math.max(3.5, size.height * 0.075);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.88)
      ..strokeWidth = math.max(2.2, size.width * 0.022)
      ..strokeCap = StrokeCap.round;

    for (var index = 0; index < barCount; index++) {
      final offset = index - (barCount - 1) / 2;
      final wave = (math.sin(phase * math.pi * 2 + index * 1.17) + 1) / 2;
      final height = minHeight + wave * amplitude;
      final arcLift = offset.abs() * size.height * 0.012;
      final x = centerX + offset * spacing;
      final bottom = baseY - arcLift;
      canvas.drawLine(
        Offset(x, bottom - height),
        Offset(x, bottom),
        paint,
      );
    }
  }

  void _paintBufferingArc(Canvas canvas, Size size) {
    final inset = math.max(2.5, size.width * 0.025);
    final ringRect = (Offset.zero & size).deflate(inset);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.2, size.width * 0.022)
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.82);
    const segmentCount = 9;
    const coveredArc = math.pi * 1.55;
    const segmentSweep = coveredArc / segmentCount * 0.55;
    final start = phase * math.pi * 2 - math.pi / 2;

    for (var index = 0; index < segmentCount; index++) {
      canvas.drawArc(
        ringRect,
        start + index * coveredArc / segmentCount,
        segmentSweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MediaPlaybackActivityPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.kind != kind ||
        oldDelegate.phase != phase;
  }
}
