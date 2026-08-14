import 'package:flutter/material.dart';

import '../../src/ui/motion.dart';
import '../animated_accent.dart';
import '../media_playback_activity_indicator.dart';
import 'orbit_peer_presentation.dart';

class DeviceOrbitPeer extends StatefulWidget {
  const DeviceOrbitPeer({
    super.key,
    required this.peer,
    required this.size,
    required this.semanticRole,
    required this.onTap,
    required this.onInteractionChanged,
    this.isNewlyPaired = false,
    this.onPairingAnimationCompleted,
  });

  final OrbitPeerPresentation peer;
  final double size;
  final String semanticRole;
  final VoidCallback onTap;
  final ValueChanged<bool> onInteractionChanged;
  final bool isNewlyPaired;
  final ValueChanged<String>? onPairingAnimationCompleted;

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

  void _handlePairingAnimationCompleted() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isNewlyPaired) return;
      widget.onPairingAnimationCompleted?.call(widget.peer.deviceId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final targetAccent =
        widget.peer.accentColor ?? Theme.of(context).colorScheme.primary;
    return AnimatedAccent(
      color: targetAccent,
      builder: _buildPeer,
    );
  }

  Widget _buildPeer(BuildContext context, Color accent) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final peer = widget.peer;
    final highlighted = _interacting;
    final status = peer.statusLabel;
    final powerStatus = peer.statusKind == OrbitPeerStatusKind.trustedOnline
        ? peer.powerStatus
        : null;
    final availabilityDescription = switch (peer.statusKind) {
      OrbitPeerStatusKind.nearby => 'ready to pair',
      OrbitPeerStatusKind.trustedOffline => 'offline',
      OrbitPeerStatusKind.trustedOnline when powerStatus != null =>
        'online, battery ${powerStatus.batteryPercent} percent${powerStatus.isCharging ? ', charging' : ''}',
      OrbitPeerStatusKind.trustedOnline => 'online',
    };
    final mediaDescription = switch (peer.activity) {
      OrbitPeerActivity.mediaPlaying =>
        ', playing ${peer.mediaTitle ?? 'media'}${peer.mediaArtist == null ? '' : ' by ${peer.mediaArtist}'}',
      OrbitPeerActivity.mediaPaused => ', ${peer.mediaTitle ?? 'media'} paused',
      OrbitPeerActivity.mediaBuffering =>
        ', buffering ${peer.mediaTitle ?? 'media'}',
      OrbitPeerActivity.none => '',
    };
    final mediaStateKey = switch (peer.activity) {
      OrbitPeerActivity.mediaPlaying => 'playing',
      OrbitPeerActivity.mediaPaused => 'paused',
      OrbitPeerActivity.mediaBuffering => 'buffering',
      OrbitPeerActivity.none => null,
    };

    final peerContent = Semantics(
      button: true,
      label:
          '${peer.displayName}, ${widget.semanticRole}, $availabilityDescription$mediaDescription',
      child: KeyedSubtree(
        key: mediaStateKey == null
            ? null
            : ValueKey(
                'orbit-peer-media-$mediaStateKey-${peer.deviceId}',
              ),
        child: AnimatedScale(
          duration: RiftMotion.durationOf(context, RiftMotion.fast),
          curve: RiftMotion.emphasis,
          scale: highlighted ? 1.02 : 1,
          child: Container(
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onTap,
                    onHover: (value) => _updateInteraction(hovered: value),
                    onFocusChange: (value) =>
                        _updateInteraction(focused: value),
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
                                : colors.onSurfaceVariant
                                    .withValues(alpha: 0.7),
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
                          if (status != null) ...[
                            const SizedBox(height: 5),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (powerStatus != null) ...[
                                    Icon(
                                      powerStatus.isCharging
                                          ? Icons.battery_charging_full
                                          : Icons.battery_std,
                                      key: ValueKey(
                                        'orbit-peer-battery-${peer.deviceId}',
                                      ),
                                      size: 13,
                                      color: accent,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '${powerStatus.batteryPercent}%',
                                      style:
                                          theme.textTheme.labelSmall?.copyWith(
                                        color: accent,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ] else ...[
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: peer.isOnline
                                            ? accent
                                            : colors.outline,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      status,
                                      style:
                                          theme.textTheme.labelSmall?.copyWith(
                                        color: peer.isOnline
                                            ? accent
                                            : colors.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                  if (peer.isOnline &&
                                      peer.activity !=
                                          OrbitPeerActivity.none) ...[
                                    const SizedBox(width: 6),
                                    _PlaybackStatusGlyph(
                                      deviceId: peer.deviceId,
                                      activity: peer.activity,
                                      color: accent,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (peer.accentColor != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: SizedBox(
                        key: ValueKey(
                          'orbit-peer-media-accented-${peer.deviceId}',
                        ),
                      ),
                    ),
                  ),
                if (peer.activity == OrbitPeerActivity.mediaPlaying ||
                    peer.activity == OrbitPeerActivity.mediaBuffering)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: MediaPlaybackActivityIndicator(
                        size: widget.size,
                        color: accent,
                        kind: peer.activity == OrbitPeerActivity.mediaPlaying
                            ? MediaPlaybackActivityKind.playing
                            : MediaPlaybackActivityKind.buffering,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      key: ValueKey(
        'device-orbit-peer-entry-${peer.deviceId}-${widget.isNewlyPaired}',
      ),
      tween: Tween<double>(
        begin: widget.isNewlyPaired ? 0 : 1,
        end: 1,
      ),
      duration: widget.isNewlyPaired
          ? RiftMotion.durationOf(context, RiftMotion.scene)
          : Duration.zero,
      curve: RiftMotion.emphasis,
      onEnd: widget.isNewlyPaired ? _handlePairingAnimationCompleted : null,
      child: peerContent,
      builder: (context, progress, child) {
        return KeyedSubtree(
          key: widget.isNewlyPaired
              ? ValueKey('recently-paired-orbit-peer-${peer.deviceId}')
              : null,
          child: SizedBox.square(
            dimension: widget.size,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                if (widget.isNewlyPaired)
                  IgnorePointer(
                    child: Opacity(
                      opacity: (1 - progress).clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 0.82 + progress * 0.78,
                        child: Container(
                          width: widget.size,
                          height: widget.size,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: accent.withValues(alpha: 0.55),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                child!,
              ],
            ),
          ),
        );
      },
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

class _PlaybackStatusGlyph extends StatelessWidget {
  const _PlaybackStatusGlyph({
    required this.deviceId,
    required this.activity,
    required this.color,
  });

  final String deviceId;
  final OrbitPeerActivity activity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      key: ValueKey('orbit-peer-status-${activity.name}-$deviceId'),
      dimension: 13,
      child: switch (activity) {
        OrbitPeerActivity.mediaPlaying => Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StatusBar(height: 6, color: color),
              _StatusBar(height: 11, color: color),
              _StatusBar(height: 8, color: color),
            ],
          ),
        OrbitPeerActivity.mediaPaused => Icon(
            Icons.pause,
            size: 13,
            color: color,
          ),
        OrbitPeerActivity.mediaBuffering => Icon(
            Icons.sync,
            size: 12,
            color: color,
          ),
        OrbitPeerActivity.none => const SizedBox.shrink(),
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 2,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}
