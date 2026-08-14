import 'package:flutter/material.dart';

import '../../src/ui/motion.dart';
import 'orbit_peer_presentation.dart';

class DeviceOrbitPeer extends StatefulWidget {
  const DeviceOrbitPeer({
    super.key,
    required this.peer,
    required this.size,
    required this.semanticRole,
    required this.onTap,
    required this.onInteractionChanged,
  });

  final OrbitPeerPresentation peer;
  final double size;
  final String semanticRole;
  final VoidCallback onTap;
  final ValueChanged<bool> onInteractionChanged;

  @override
  State<DeviceOrbitPeer> createState() => _DeviceOrbitPeerState();
}

class _DeviceOrbitPeerState extends State<DeviceOrbitPeer> {
  bool _hovered = false;
  bool _focused = false;

  bool get _interacting => _hovered || _focused;

  void _updateInteraction({bool? hovered, bool? focused}) {
    final wasInteracting = _interacting;
    setState(() {
      if (hovered != null) _hovered = hovered;
      if (focused != null) _focused = focused;
    });
    if (wasInteracting != _interacting) {
      widget.onInteractionChanged(_interacting);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final peer = widget.peer;
    final accent = peer.accentColor ?? colors.primary;
    final highlighted = _interacting;
    final status = peer.isOnline ? 'Online' : 'Offline';
    final mediaDescription = switch (peer.activity) {
      OrbitPeerActivity.mediaPlaying =>
        ', playing ${peer.mediaTitle ?? 'media'}${peer.mediaArtist == null ? '' : ' by ${peer.mediaArtist}'}',
      OrbitPeerActivity.mediaPaused => ', ${peer.mediaTitle ?? 'media'} paused',
      OrbitPeerActivity.none => '',
    };

    return Semantics(
      button: true,
      label:
          '${peer.displayName}, ${widget.semanticRole}, ${status.toLowerCase()}$mediaDescription',
      child: KeyedSubtree(
        key: peer.activity == OrbitPeerActivity.none
            ? null
            : ValueKey(
                'orbit-peer-media-${peer.activity == OrbitPeerActivity.mediaPlaying ? 'playing' : 'paused'}-${peer.deviceId}',
              ),
        child: AnimatedScale(
          duration: RiftMotion.durationOf(context, RiftMotion.fast),
          curve: RiftMotion.emphasis,
          scale: highlighted ? 1.02 : 1,
          child: AnimatedContainer(
            duration: RiftMotion.durationOf(context, RiftMotion.slow),
            curve: RiftMotion.move,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.alphaBlend(
                accent.withValues(alpha: peer.isOnline ? 0.08 : 0.025),
                colors.surface,
              ),
              border: Border.all(
                color: highlighted
                    ? accent
                    : Color.lerp(colors.outlineVariant, accent, 0.35)!,
                width: highlighted ? 2 : 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(
                    alpha:
                        peer.activity == OrbitPeerActivity.none ? 0.06 : 0.18,
                  ),
                  blurRadius: peer.activity == OrbitPeerActivity.none ? 16 : 26,
                  spreadRadius: peer.activity == OrbitPeerActivity.none ? 0 : 2,
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onTap,
                onHover: (value) => _updateInteraction(hovered: value),
                onFocusChange: (value) => _updateInteraction(focused: value),
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _platformIcon(peer.platform),
                        size: widget.size < 112 ? 24 : 28,
                        color: peer.isOnline
                            ? accent
                            : colors.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        peer.displayName,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 5),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: peer.isOnline ? accent : colors.outline,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              status,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: peer.isOnline
                                    ? accent
                                    : colors.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                                fontSize: 10,
                              ),
                            ),
                          ],
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
  }

  IconData _platformIcon(String platform) => switch (platform.toLowerCase()) {
        'android' || 'ios' => Icons.smartphone,
        'windows' => Icons.desktop_windows,
        'macos' => Icons.laptop_mac,
        'linux' => Icons.computer,
        _ => Icons.devices,
      };
}
