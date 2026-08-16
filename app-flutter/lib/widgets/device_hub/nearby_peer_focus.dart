import 'package:flutter/material.dart';

class NearbyPeerFocus extends StatelessWidget {
  const NearbyPeerFocus({
    super.key,
    required this.deviceId,
    this.identityLabel = 'Device ID',
    required this.displayName,
    required this.platform,
    required this.endpoint,
    required this.onClose,
    required this.onPair,
  });

  final String deviceId;
  final String identityLabel;
  final String displayName;
  final String platform;
  final String? endpoint;
  final VoidCallback onClose;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final normalizedPlatform = platform.trim().toLowerCase();
    final showPlatform = const {
      'android',
      'ios',
      'windows',
      'macos',
      'linux',
    }.contains(normalizedPlatform);
    return Semantics(
      label: '$displayName, nearby device, ready to pair',
      child: Stack(
        key: ValueKey('nearby-peer-focus-$deviceId'),
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  colors.primary.withValues(alpha: 0.08),
                  colors.surface.withValues(alpha: 0),
                ],
              ),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: IconButton(
              key: const ValueKey('nearby-focus-close'),
              tooltip: 'Close nearby device',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 148,
                      height: 148,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color.alphaBlend(
                          colors.primary.withValues(alpha: 0.08),
                          colors.surface,
                        ),
                        border: Border.all(color: colors.primary, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: colors.primary.withValues(alpha: 0.14),
                            blurRadius: 28,
                          ),
                        ],
                      ),
                      child: Icon(
                        _platformIcon(platform),
                        size: 46,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      displayName,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (showPlatform) ...[
                      const SizedBox(height: 6),
                      Text(
                        normalizedPlatform.toUpperCase(),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      identityLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      deviceId,
                      key: const ValueKey('nearby-focus-device-id'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurface,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                    if (endpoint != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        endpoint!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontFamily: 'JetBrains Mono',
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const ValueKey('nearby-pair-action'),
                      onPressed: onPair,
                      icon: const Icon(Icons.link),
                      label: const Text('Pair'),
                    ),
                  ],
                ),
              ),
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
