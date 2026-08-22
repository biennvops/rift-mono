import 'package:flutter/material.dart';

import 'device_platform_presentation.dart';
import 'device_summary_status.dart';
import 'orbit_peer_presentation.dart';

class NearbyPeerFocus extends StatelessWidget {
  const NearbyPeerFocus({
    super.key,
    required this.presentation,
    required this.endpoint,
    required this.onClose,
    required this.onPair,
  });

  final OrbitPeerPresentation presentation;
  final String? endpoint;
  final VoidCallback onClose;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final platformLabel = devicePlatformLabel(presentation.platform);
    return Semantics(
      container: true,
      label: presentation.semanticDescription(),
      child: Stack(
        key: ValueKey('nearby-peer-focus-${presentation.deviceId}'),
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
                        devicePlatformIcon(presentation.platform),
                        size: 46,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      presentation.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (platformLabel != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        platformLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DeviceSummaryStatus(
                      presentation: presentation,
                      accentColor: colors.primary,
                      alignment: WrapAlignment.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Ready to pair',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Device ID',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      presentation.deviceId,
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
}
