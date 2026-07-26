import 'dart:ui';

import 'package:flutter/material.dart';

class FileDropOverlay extends StatefulWidget {
  final int activeDeviceCount;
  final bool isVisible;

  const FileDropOverlay({
    super.key,
    this.activeDeviceCount = 0,
    this.isVisible = false,
  });

  @override
  State<FileDropOverlay> createState() => _FileDropOverlayState();
}

class _FileDropOverlayState extends State<FileDropOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _borderOpacity;
  late Animation<double> _pingScale;
  late Animation<double> _pingOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _borderOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.5, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.5), weight: 50),
    ]).animate(_controller);

    _pingScale = Tween<double>(begin: 1.0, end: 2.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.75, curve: Curves.easeOut),
      ),
    );

    _pingOpacity = Tween<double>(begin: 0.2, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.75, curve: Curves.easeOut),
      ),
    );

    if (widget.isVisible) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant FileDropOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible && !oldWidget.isVisible) {
      _controller.repeat();
    } else if (!widget.isVisible && oldWidget.isVisible) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isVisible) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Positioned.fill(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            color: Colors.white.withValues(alpha: 0.85),
            padding: const EdgeInsets.all(32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 768,
                  maxHeight: 600,
                ),
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    return CustomPaint(
                      painter: _DashedBorderPainter(
                        color: theme.colorScheme.primaryContainer
                            .withValues(alpha: _borderOpacity.value),
                        strokeWidth: 4,
                        gap: 8,
                        borderRadius: 24,
                      ),
                      child: child,
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildPulsingIcon(theme),
                        const SizedBox(height: 32),
                        Text(
                          'Drop files to send',
                          style: theme.textTheme.headlineLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Securely sync these files to all active devices connected to your Rift network.',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.secondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 48),
                        if (widget.activeDeviceCount > 0)
                          _buildDeviceStack(theme, widget.activeDeviceCount),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPulsingIcon(ThemeData theme) {
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
        shape: BoxShape.circle,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Transform.scale(
                scale: _pingScale.value,
                child: Opacity(
                  opacity: _pingOpacity.value,
                  child: Container(
                    width: 128,
                    height: 128,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.primaryContainer,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Icon(
            Icons.devices,
            size: 64,
            color: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceStack(ThemeData theme, int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48 + ((count.clamp(1, 3) - 1) * 32.0),
          height: 48,
          child: Stack(
            children: List.generate(count.clamp(1, 3), (index) {
              final icons = [Icons.laptop_mac, Icons.smartphone, Icons.tablet_mac];
              return Positioned(
                left: index * 32.0,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.surfaceContainerLowest,
                      width: 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    icons[index % icons.length],
                    size: 20,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              );
            }).reversed.toList(),
          ),
        ),
        const SizedBox(width: 16),
        Text(
          'Sending to $count device${count > 1 ? 's' : ''}',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.secondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;
  final double borderRadius;

  _DashedBorderPainter({
    required this.color,
    required this.strokeWidth,
    required this.gap,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Radius.circular(borderRadius),
      ));

    final dashPath = Path();
    var distance = 0.0;
    for (final metric in path.computeMetrics()) {
      while (distance < metric.length) {
        final dashLength = gap * 1.5;
        dashPath.addPath(
          metric.extractPath(distance, distance + dashLength),
          Offset.zero,
        );
        distance += dashLength + gap;
      }
      distance = 0.0;
    }

    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.gap != gap ||
        oldDelegate.borderRadius != borderRadius;
  }
}
