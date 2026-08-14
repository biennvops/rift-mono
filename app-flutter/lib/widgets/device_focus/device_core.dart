import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../media_playback_activity_indicator.dart';

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
    this.statusLabel,
    this.accentColor,
    this.isMediaPlaying = false,
    this.isMediaBuffering = false,
  });

  final double size;
  final String displayName;
  final IconData platformIcon;
  final bool isOnline;
  final Animation<double> entrance;
  final Animation<double> online;
  final Animation<double> wake;
  final String? statusLabel;
  final Color? accentColor;
  final bool isMediaPlaying;
  final bool isMediaBuffering;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final resolvedStatus = statusLabel ?? (isOnline ? 'Online' : 'Offline');
    return Semantics(
      label: '$displayName, $resolvedStatus',
      child: AnimatedBuilder(
        animation: Listenable.merge([entrance, online, wake]),
        builder: (context, child) {
          final entranceProgress = Curves.easeOutCubic.transform(
            (entrance.value / 0.38).clamp(0.0, 1.0).toDouble(),
          );
          final defaultAccent =
              Color.lerp(colors.outline, colors.primary, online.value)!;
          final accent = accentColor ?? defaultAccent;
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
                            color: accent.withValues(
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
                    padding: EdgeInsets.all(size < 155 ? 12 : 18),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.alphaBlend(
                        accent.withValues(
                          alpha: 0.025 + online.value * 0.055,
                        ),
                        colors.surface,
                      ),
                      border: Border.all(color: accent, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(
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
                          size: size < 155 ? 26 : 38,
                          color: accent,
                        ),
                        SizedBox(height: size < 155 ? 4 : 10),
                        Text(
                          displayName,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: colors.onSurface,
                                    fontWeight: FontWeight.w700,
                                    fontSize: size < 155 ? 14 : null,
                                    height: 1.1,
                                  ),
                        ),
                        SizedBox(height: size < 155 ? 4 : 8),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: size < 155 ? 6 : 9,
                            vertical: size < 155 ? 2 : 4,
                          ),
                          decoration: BoxDecoration(
                            color: Color.alphaBlend(
                              accent.withValues(
                                alpha: 0.04 + online.value * 0.08,
                              ),
                              colors.surfaceContainerHighest,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: size < 155 ? 6 : 7,
                                  height: size < 155 ? 6 : 7,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: accent,
                                  ),
                                ),
                                SizedBox(width: size < 155 ? 4 : 6),
                                Text(
                                  resolvedStatus,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        fontSize: size < 155 ? 10 : null,
                                        height: 1.2,
                                        color: accent,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isMediaPlaying || isMediaBuffering)
                    IgnorePointer(
                      child: MediaPlaybackActivityIndicator(
                        size: size,
                        color: accent,
                        kind: isMediaPlaying
                            ? MediaPlaybackActivityKind.playing
                            : MediaPlaybackActivityKind.buffering,
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
