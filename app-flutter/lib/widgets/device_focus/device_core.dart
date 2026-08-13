import 'dart:math' as math;

import 'package:flutter/material.dart';

class DeviceCore extends StatelessWidget {
  const DeviceCore({
    super.key,
    required this.size,
    required this.displayName,
    required this.platformIcon,
    required this.isOnline,
    required this.entrance,
    required this.online,
    required this.wake,
  });

  final double size;
  final String displayName;
  final IconData platformIcon;
  final bool isOnline;
  final Animation<double> entrance;
  final Animation<double> online;
  final Animation<double> wake;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '$displayName, ${isOnline ? 'Online' : 'Offline'}',
      child: AnimatedBuilder(
        animation: Listenable.merge([entrance, online, wake]),
        builder: (context, child) {
          final entranceProgress = Curves.easeOutCubic.transform(
            (entrance.value / 0.38).clamp(0.0, 1.0).toDouble(),
          );
          final accent =
              Color.lerp(colors.outline, colors.primary, online.value)!;
          final pulseOpacity =
              math.sin(wake.value * math.pi) * 0.22 * online.value;

          return Opacity(
            opacity: entranceProgress,
            child: Transform.scale(
              scale: 0.9 + entranceProgress * 0.1,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  if (pulseOpacity > 0)
                    Transform.scale(
                      scale: 1 + wake.value * 0.22,
                      child: Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.primary.withValues(
                              alpha: pulseOpacity,
                            ),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  Container(
                    key: const ValueKey('device-focus-core'),
                    width: size,
                    height: size,
                    padding: EdgeInsets.all(size < 145 ? 14 : 18),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.lerp(
                        colors.surface,
                        colors.primaryContainer.withValues(alpha: 0.08),
                        online.value,
                      ),
                      border: Border.all(color: accent, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: colors.primary.withValues(
                            alpha: 0.04 + online.value * 0.1,
                          ),
                          blurRadius: 20 + online.value * 12,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          platformIcon,
                          size: size < 145 ? 30 : 38,
                          color: accent,
                        ),
                        SizedBox(height: size < 145 ? 6 : 10),
                        Text(
                          displayName,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: colors.onSurface,
                                    fontWeight: FontWeight.w700,
                                    height: 1.15,
                                  ),
                        ),
                        SizedBox(height: size < 145 ? 5 : 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Color.lerp(
                              colors.surfaceContainerHighest,
                              colors.primaryContainer.withValues(alpha: 0.14),
                              online.value,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isOnline ? 'Online' : 'Offline',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
