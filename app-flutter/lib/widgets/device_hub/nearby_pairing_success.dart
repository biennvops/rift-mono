import 'package:flutter/material.dart';

import '../../src/ui/motion.dart';

class NearbyPairingSuccess extends StatelessWidget {
  const NearbyPairingSuccess({
    super.key,
    required this.deviceId,
    required this.displayName,
    required this.platform,
  });

  final String deviceId;
  final String displayName;
  final String platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const success = Color(0xFF047857);
    return Semantics(
      liveRegion: true,
      label: '$displayName paired successfully',
      child: Stack(
        key: ValueKey('nearby-pairing-success-$deviceId'),
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  success.withValues(alpha: 0.12),
                  colors.surface.withValues(alpha: 0),
                ],
              ),
            ),
          ),
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: RiftMotion.durationOf(context, RiftMotion.scene),
              curve: RiftMotion.emphasis,
              builder: (context, progress, child) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 210,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Opacity(
                            opacity: (1 - progress).clamp(0, 1),
                            child: Transform.scale(
                              scale: 0.82 + progress * 0.78,
                              child: Container(
                                width: 156,
                                height: 156,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: success.withValues(alpha: 0.55),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Opacity(
                            opacity: 0.45 + progress * 0.55,
                            child: Transform.scale(
                              scale: 0.88 + progress * 0.12,
                              child: Container(
                                width: 156,
                                height: 156,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color.alphaBlend(
                                    success.withValues(alpha: 0.1),
                                    colors.surface,
                                  ),
                                  border: Border.all(color: success, width: 2),
                                  boxShadow: [
                                    BoxShadow(
                                      color: success.withValues(alpha: 0.2),
                                      blurRadius: 30,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  _platformIcon(platform),
                                  size: 48,
                                  color: success,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 24,
                            bottom: 24,
                            child: Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: success,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: colors.surface,
                                  width: 3,
                                ),
                              ),
                              child: const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      displayName,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Paired successfully',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: success,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Moving to Trusted devices…',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  IconData _platformIcon(String value) => switch (value.toLowerCase()) {
        'android' || 'ios' => Icons.smartphone,
        'windows' => Icons.desktop_windows,
        'macos' => Icons.laptop_mac,
        'linux' => Icons.computer,
        _ => Icons.devices,
      };
}
