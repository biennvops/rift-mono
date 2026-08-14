import 'package:flutter/material.dart';

import 'device_orbit_background.dart';
import 'device_orbit_layout.dart';
import 'device_orbit_peer.dart';
import 'orbit_peer_presentation.dart';

class DeviceOrbitScene extends StatelessWidget {
  const DeviceOrbitScene({
    super.key,
    required this.localDisplayName,
    required this.localPlatform,
    required this.peers,
    required this.phase,
    required this.scanProgress,
    required this.peerKeyPrefix,
    required this.peerSemanticRole,
    required this.onPeerSelected,
    required this.onPeerInteractionChanged,
    required this.onSceneFocusChanged,
    this.onLocalDeviceTap,
    this.scanning = false,
    this.emptyMessage,
    this.emptyAction,
    this.recentlyPairedDeviceId,
    this.onRecentlyPairedAnimationCompleted,
  });

  final String localDisplayName;
  final String localPlatform;
  final List<OrbitPeerPresentation> peers;
  final Animation<double> phase;
  final Animation<double> scanProgress;
  final String peerKeyPrefix;
  final String peerSemanticRole;
  final ValueChanged<OrbitPeerPresentation> onPeerSelected;
  final void Function(String deviceId, bool interacting)
      onPeerInteractionChanged;
  final ValueChanged<bool> onSceneFocusChanged;
  final VoidCallback? onLocalDeviceTap;
  final bool scanning;
  final String? emptyMessage;
  final Widget? emptyAction;
  final String? recentlyPairedDeviceId;
  final ValueChanged<String>? onRecentlyPairedAnimationCompleted;

  @override
  Widget build(BuildContext context) {
    final sortedPeers = peers.toList(growable: false)
      ..sort((left, right) => left.deviceId.compareTo(right.deviceId));
    return Focus(
      onFocusChange: onSceneFocusChanged,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final geometry = DeviceOrbitLayout.calculate(size);
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DeviceOrbitBackground(
                  geometry: geometry,
                  scanning: scanning,
                  scanProgress: scanProgress,
                ),
                Positioned(
                  left: geometry.center.dx - geometry.localCoreSize / 2,
                  top: geometry.center.dy - geometry.localCoreSize / 2,
                  child: _LocalDeviceCore(
                    size: geometry.localCoreSize,
                    displayName: localDisplayName,
                    platform: localPlatform,
                    onTap: onLocalDeviceTap,
                  ),
                ),
                for (var index = 0; index < sortedPeers.length; index++)
                  _OrbitPositionedPeer(
                    phase: phase,
                    geometry: geometry,
                    index: index,
                    peerCount: sortedPeers.length,
                    peer: sortedPeers[index],
                    peerKeyPrefix: peerKeyPrefix,
                    peerSemanticRole: peerSemanticRole,
                    onTap: () => onPeerSelected(sortedPeers[index]),
                    onInteractionChanged: (interacting) =>
                        onPeerInteractionChanged(
                      sortedPeers[index].deviceId,
                      interacting,
                    ),
                    isNewlyPaired:
                        sortedPeers[index].deviceId == recentlyPairedDeviceId,
                    onPairingAnimationCompleted:
                        onRecentlyPairedAnimationCompleted,
                  ),
                if (sortedPeers.isEmpty && emptyMessage != null)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 28,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          emptyMessage!,
                          key: const ValueKey('device-orbit-empty-message'),
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                        if (emptyAction != null) ...[
                          const SizedBox(height: 12),
                          emptyAction!,
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OrbitPositionedPeer extends StatelessWidget {
  const _OrbitPositionedPeer({
    required this.phase,
    required this.geometry,
    required this.index,
    required this.peerCount,
    required this.peer,
    required this.peerKeyPrefix,
    required this.peerSemanticRole,
    required this.onTap,
    required this.onInteractionChanged,
    required this.isNewlyPaired,
    required this.onPairingAnimationCompleted,
  });

  final Animation<double> phase;
  final DeviceOrbitGeometry geometry;
  final int index;
  final int peerCount;
  final OrbitPeerPresentation peer;
  final String peerKeyPrefix;
  final String peerSemanticRole;
  final VoidCallback onTap;
  final ValueChanged<bool> onInteractionChanged;
  final bool isNewlyPaired;
  final ValueChanged<String>? onPairingAnimationCompleted;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: phase,
        child: DeviceOrbitPeer(
          key: ValueKey('$peerKeyPrefix-${peer.deviceId}'),
          peer: peer,
          size: geometry.peerSize,
          semanticRole: peerSemanticRole,
          onTap: onTap,
          onInteractionChanged: onInteractionChanged,
          isNewlyPaired: isNewlyPaired,
          onPairingAnimationCompleted: onPairingAnimationCompleted,
        ),
        builder: (context, child) {
          final center = DeviceOrbitLayout.peerCenter(
            geometry: geometry,
            index: index,
            peerCount: peerCount,
            phase: phase.value,
          );
          return Stack(
            children: [
              Positioned(
                left: center.dx - geometry.peerSize / 2,
                top: center.dy - geometry.peerSize / 2,
                child: child!,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LocalDeviceCore extends StatelessWidget {
  const _LocalDeviceCore({
    required this.size,
    required this.displayName,
    required this.platform,
    required this.onTap,
  });

  final double size;
  final String displayName;
  final String platform;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      button: onTap != null,
      label: '$displayName, This Device',
      child: Material(
        key: const ValueKey('device-hub-local-core'),
        color: Color.alphaBlend(
          colors.primary.withValues(alpha: 0.08),
          colors.surface,
        ),
        shape: CircleBorder(
          side: BorderSide(color: colors.primary, width: 2),
        ),
        elevation: 5,
        shadowColor: colors.primary.withValues(alpha: 0.22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _platformIcon(platform),
                    size: size < 145 ? 30 : 38,
                    color: colors.primary,
                  ),
                  const SizedBox(height: 9),
                  Text(
                    displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'This Device',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
