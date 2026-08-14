import 'package:flutter/material.dart';

import 'motion.dart';

/// Keeps all indexed children mounted while animating between active sections.
class RiftIndexedTransitionStack extends StatefulWidget {
  const RiftIndexedTransitionStack({
    super.key,
    required this.index,
    required this.children,
    this.direction,
  }) : assert(children.length > 0);

  final int index;
  final List<Widget> children;

  /// A positive value moves forward through the section order, and a negative
  /// value moves backward. When omitted, the index difference is used.
  final int? direction;

  @override
  State<RiftIndexedTransitionStack> createState() =>
      _RiftIndexedTransitionStackState();
}

class _RiftIndexedTransitionStackState extends State<RiftIndexedTransitionStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late int _activeIndex;
  int? _outgoingIndex;
  int _direction = 1;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _activeIndex = _validIndex(widget.index, widget.children.length);
    _controller = AnimationController(
      vsync: this,
      duration: RiftMotion.normal,
      value: 1,
    )..addStatusListener(_handleAnimationStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = RiftMotion.reducedMotionOf(context);
    if (reducedMotion == _reducedMotion) return;

    _reducedMotion = reducedMotion;
    if (reducedMotion) {
      _controller.stop();
      _outgoingIndex = null;
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(RiftIndexedTransitionStack oldWidget) {
    super.didUpdateWidget(oldWidget);

    final nextIndex = _validIndex(widget.index, widget.children.length);
    final previousIndex = _activeIndex;
    if (nextIndex == previousIndex) {
      if (_outgoingIndex != null) {
        _direction = _resolveDirection(widget.direction, _direction);
      }
      return;
    }

    _activeIndex = nextIndex;
    _direction = _resolveDirection(
      widget.direction,
      nextIndex > previousIndex ? 1 : -1,
    );
    _reducedMotion = RiftMotion.reducedMotionOf(context);

    _controller.stop();
    if (_reducedMotion) {
      _outgoingIndex = null;
      _controller.value = 1;
      return;
    }

    _outgoingIndex =
        previousIndex < widget.children.length ? previousIndex : null;
    _controller.value = 0;
    _controller.forward();
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _outgoingIndex == null) {
      return;
    }
    if (mounted) {
      setState(() => _outgoingIndex = null);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => _buildStack(),
    );
  }

  Widget _buildStack() {
    final progress =
        _reducedMotion ? 1.0 : RiftMotion.enter.transform(_controller.value);
    final outgoingProgress =
        _reducedMotion ? 1.0 : RiftMotion.exit.transform(_controller.value);
    final incomingOffset = Offset(12 * _direction.toDouble(), 0);
    final outgoingOffset = Offset(-6 * _direction.toDouble(), 0);

    return Stack(
      fit: StackFit.expand,
      children: [
        for (var index = 0; index < widget.children.length; index++)
          _buildChild(
            index: index,
            isActive: index == _activeIndex,
            isOutgoing: index == _outgoingIndex,
            progress: progress,
            outgoingProgress: outgoingProgress,
            incomingOffset: incomingOffset,
            outgoingOffset: outgoingOffset,
          ),
      ],
    );
  }

  Widget _buildChild({
    required int index,
    required bool isActive,
    required bool isOutgoing,
    required double progress,
    required double outgoingProgress,
    required Offset incomingOffset,
    required Offset outgoingOffset,
  }) {
    final isVisible = isActive || isOutgoing;
    final opacity = isOutgoing ? 1 - outgoingProgress : progress;
    final offset = isOutgoing
        ? Offset.lerp(Offset.zero, outgoingOffset, outgoingProgress)!
        : Offset.lerp(incomingOffset, Offset.zero, progress)!;

    return TickerMode(
      enabled: isVisible,
      child: IgnorePointer(
        ignoring: !isActive,
        child: ExcludeFocus(
          excluding: !isActive,
          child: ExcludeSemantics(
            excluding: !isActive,
            child: Offstage(
              offstage: !isVisible,
              child: Opacity(
                opacity: opacity,
                child: Transform.translate(
                  offset: offset,
                  child: widget.children[index],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static int _validIndex(int index, int length) {
    if (length == 0) return 0;
    return index.clamp(0, length - 1).toInt();
  }

  static int _resolveDirection(int? direction, int fallback) {
    if (direction == null || direction == 0) return fallback;
    return direction < 0 ? -1 : 1;
  }
}
