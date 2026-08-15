import 'package:flutter/material.dart';

import 'device_focus_layout.dart';
import '../../src/ui/motion.dart';

class DeviceFocusNode extends StatefulWidget {
  const DeviceFocusNode({
    super.key,
    required this.kind,
    required this.icon,
    required this.value,
    required this.label,
    required this.size,
    required this.isSelected,
    required this.entrance,
    required this.entranceIndex,
    required this.entranceOffset,
    required this.onTap,
    required this.onInteractionChanged,
    this.focusNode,
    this.accentColor,
  });

  final DeviceFocusNodeKind kind;
  final IconData icon;
  final String value;
  final String label;
  final Size size;
  final bool isSelected;
  final Animation<double> entrance;
  final int entranceIndex;
  final Offset entranceOffset;
  final VoidCallback onTap;
  final ValueChanged<bool> onInteractionChanged;
  final FocusNode? focusNode;
  final Color? accentColor;

  @override
  State<DeviceFocusNode> createState() => _DeviceFocusNodeState();
}

class _DeviceFocusNodeState extends State<DeviceFocusNode> {
  bool _isHovered = false;
  bool _isFocused = false;

  bool get _isEngaged => _isHovered || _isFocused;

  void _updateInteraction({bool? hovered, bool? focused}) {
    final wasEngaged = _isEngaged;
    setState(() {
      if (hovered != null) _isHovered = hovered;
      if (focused != null) _isFocused = focused;
    });
    if (wasEngaged != _isEngaged) {
      widget.onInteractionChanged(_isEngaged);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = widget.accentColor ?? colors.primary;
    final highlighted = _isEngaged || widget.isSelected;
    final motionDuration = RiftMotion.durationOf(
      context,
      widget.accentColor == null ? RiftMotion.fast : RiftMotion.slow,
    );
    final begin = 0.34 + widget.entranceIndex * 0.065;
    final end = (begin + 0.3).clamp(0.0, 0.92).toDouble();

    final interactiveNode = AnimatedSlide(
      duration: motionDuration,
      curve: Curves.easeOutCubic,
      offset: highlighted ? const Offset(0, -0.035) : Offset.zero,
      child: AnimatedScale(
        duration: motionDuration,
        curve: Curves.easeOutCubic,
        scale: highlighted ? 1.035 : 1,
        child: Container(
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              accent.withValues(
                alpha: widget.isSelected ? 0.11 : 0.035,
              ),
              colors.surface,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: highlighted ? accent : colors.outlineVariant,
              width: highlighted ? 1.5 : 1,
            ),
            boxShadow: highlighted
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.1),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const [],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              button: true,
              selected: widget.isSelected,
              label: '${widget.label}, ${widget.value}. Show details',
              child: InkWell(
                focusNode: widget.focusNode,
                onTap: widget.onTap,
                onHover: (value) => _updateInteraction(hovered: value),
                onFocusChange: (value) => _updateInteraction(focused: value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        widget.icon,
                        size: 20,
                        color: highlighted ? accent : colors.onSurfaceVariant,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return SizedBox.fromSize(
      size: widget.size,
      child: AnimatedBuilder(
        animation: widget.entrance,
        child: interactiveNode,
        builder: (context, child) {
          final progress = Curves.easeOutQuart.transform(
            ((widget.entrance.value - begin) / (end - begin))
                .clamp(0.0, 1.0)
                .toDouble(),
          );
          return Opacity(
            opacity: progress,
            child: Transform.translate(
              offset: widget.entranceOffset * (1 - progress),
              child: Transform.scale(
                scale: 0.92 + progress * 0.08,
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}
