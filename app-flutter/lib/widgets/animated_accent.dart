import 'package:flutter/material.dart';

import '../src/ui/motion.dart';

typedef AnimatedAccentBuilder = Widget Function(
  BuildContext context,
  Color accent,
);

class AnimatedAccent extends StatefulWidget {
  const AnimatedAccent({
    super.key,
    required this.color,
    required this.builder,
    this.duration = const Duration(milliseconds: 600),
  });

  final Color color;
  final AnimatedAccentBuilder builder;
  final Duration duration;

  @override
  State<AnimatedAccent> createState() => _AnimatedAccentState();
}

class _AnimatedAccentState extends State<AnimatedAccent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Color _from;
  late Color _to;

  @override
  void initState() {
    super.initState();
    _from = widget.color;
    _to = widget.color;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (RiftMotion.reducedMotionOf(context) && _controller.value != 1) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(AnimatedAccent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.color == _to) return;

    _from = Color.lerp(
      _from,
      _to,
      RiftMotion.move.transform(_controller.value),
    )!;
    _to = widget.color;
    if (RiftMotion.reducedMotionOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = RiftMotion.move.transform(_controller.value);
        return widget.builder(context, Color.lerp(_from, _to, progress)!);
      },
    );
  }
}
