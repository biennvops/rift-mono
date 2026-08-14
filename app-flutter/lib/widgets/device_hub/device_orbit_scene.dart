import 'package:flutter/material.dart';

import '../../src/ui/motion.dart';
import 'device_orbit_background.dart';
import 'device_orbit_layout.dart';
import 'device_orbit_peer.dart';
import 'orbit_peer_presentation.dart';

class DeviceOrbitScene extends StatefulWidget {
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
    this.animatePeerChanges = false,
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
  final bool animatePeerChanges;
  final String? emptyMessage;
  final Widget? emptyAction;
  final String? recentlyPairedDeviceId;
  final ValueChanged<String>? onRecentlyPairedAnimationCompleted;

  @override
  State<DeviceOrbitScene> createState() => _DeviceOrbitSceneState();
}

class _DeviceOrbitSceneState extends State<DeviceOrbitScene> {
  final Map<String, _OutgoingOrbitPeer> _outgoingPeers =
      <String, _OutgoingOrbitPeer>{};

  @override
  void didUpdateWidget(DeviceOrbitScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.animatePeerChanges) {
      _outgoingPeers.clear();
      return;
    }

    final currentIds = widget.peers.map((peer) => peer.deviceId).toSet();
    final previousPeers = _sortedPeers(oldWidget.peers);
    for (var index = 0; index < previousPeers.length; index++) {
      final peer = previousPeers[index];
      if (!currentIds.contains(peer.deviceId)) {
        _outgoingPeers[peer.deviceId] = _OutgoingOrbitPeer(
          peer: peer,
          index: index,
          peerCount: previousPeers.length,
        );
      }
    }
    for (final peer in widget.peers) {
      _outgoingPeers.remove(peer.deviceId);
    }
  }

  List<OrbitPeerPresentation> _sortedPeers(
    Iterable<OrbitPeerPresentation> peers,
  ) {
    return peers.toList(growable: false)
      ..sort((left, right) => left.deviceId.compareTo(right.deviceId));
  }

  void _removeOutgoingPeer(String deviceId) {
    if (!mounted || !_outgoingPeers.containsKey(deviceId)) return;
    setState(() => _outgoingPeers.remove(deviceId));
  }

  @override
  Widget build(BuildContext context) {
    final sortedPeers = _sortedPeers(widget.peers);
    final presenceDuration = RiftMotion.durationOf(context, RiftMotion.normal);
    return Focus(
      onFocusChange: widget.onSceneFocusChanged,
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
                  scanning: widget.scanning,
                  scanProgress: widget.scanProgress,
                ),
                Positioned(
                  left: geometry.center.dx - geometry.localCoreSize / 2,
                  top: geometry.center.dy - geometry.localCoreSize / 2,
                  child: _LocalDeviceCore(
                    size: geometry.localCoreSize,
                    displayName: widget.localDisplayName,
                    platform: widget.localPlatform,
                    onTap: widget.onLocalDeviceTap,
                  ),
                ),
                for (final outgoing in _outgoingPeers.values)
                  _OrbitPositionedPeer(
                    key: ValueKey(
                      '${widget.peerKeyPrefix}-slot-${outgoing.peer.deviceId}',
                    ),
                    phase: widget.phase,
                    geometry: geometry,
                    index: outgoing.index,
                    peerCount: outgoing.peerCount,
                    peer: outgoing.peer,
                    peerKeyPrefix: widget.peerKeyPrefix,
                    peerSemanticRole: widget.peerSemanticRole,
                    onTap: () => widget.onPeerSelected(outgoing.peer),
                    onInteractionChanged: (interacting) =>
                        widget.onPeerInteractionChanged(
                      outgoing.peer.deviceId,
                      interacting,
                    ),
                    isNewlyPaired: false,
                    onPairingAnimationCompleted: null,
                    present: false,
                    animatePresence: true,
                    presenceDuration: presenceDuration,
                    onPresenceDismissed: () =>
                        _removeOutgoingPeer(outgoing.peer.deviceId),
                  ),
                for (var index = 0; index < sortedPeers.length; index++)
                  _OrbitPositionedPeer(
                    key: ValueKey(
                      '${widget.peerKeyPrefix}-slot-${sortedPeers[index].deviceId}',
                    ),
                    phase: widget.phase,
                    geometry: geometry,
                    index: index,
                    peerCount: sortedPeers.length,
                    peer: sortedPeers[index],
                    peerKeyPrefix: widget.peerKeyPrefix,
                    peerSemanticRole: widget.peerSemanticRole,
                    onTap: () => widget.onPeerSelected(sortedPeers[index]),
                    onInteractionChanged: (interacting) =>
                        widget.onPeerInteractionChanged(
                      sortedPeers[index].deviceId,
                      interacting,
                    ),
                    isNewlyPaired: sortedPeers[index].deviceId ==
                        widget.recentlyPairedDeviceId,
                    onPairingAnimationCompleted:
                        widget.onRecentlyPairedAnimationCompleted,
                    present: true,
                    animatePresence: widget.animatePeerChanges,
                    presenceDuration: presenceDuration,
                    onPresenceDismissed: null,
                  ),
                if (sortedPeers.isEmpty &&
                    _outgoingPeers.isEmpty &&
                    widget.emptyMessage != null)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 28,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.emptyMessage!,
                          key: const ValueKey('device-orbit-empty-message'),
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                        if (widget.emptyAction != null) ...[
                          const SizedBox(height: 12),
                          widget.emptyAction!,
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

class _OutgoingOrbitPeer {
  const _OutgoingOrbitPeer({
    required this.peer,
    required this.index,
    required this.peerCount,
  });

  final OrbitPeerPresentation peer;
  final int index;
  final int peerCount;
}

class _OrbitPositionedPeer extends StatelessWidget {
  const _OrbitPositionedPeer({
    super.key,
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
    required this.present,
    required this.animatePresence,
    required this.presenceDuration,
    required this.onPresenceDismissed,
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
  final bool present;
  final bool animatePresence;
  final Duration presenceDuration;
  final VoidCallback? onPresenceDismissed;

  @override
  Widget build(BuildContext context) {
    final peerContent = ExcludeSemantics(
      excluding: !present,
      child: ExcludeFocus(
        excluding: !present,
        child: IgnorePointer(
          ignoring: !present,
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
        ),
      ),
    );
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: phase,
        child: TweenAnimationBuilder<double>(
          key: ValueKey('$peerKeyPrefix-presence-animation-${peer.deviceId}'),
          tween: Tween<double>(
            begin: present ? 0 : 1,
            end: present ? 1 : 0,
          ),
          duration: animatePresence ? presenceDuration : Duration.zero,
          curve: present ? RiftMotion.enter : RiftMotion.exit,
          onEnd: present ? null : onPresenceDismissed,
          child: peerContent,
          builder: (context, progress, child) {
            return Opacity(
              key: ValueKey('$peerKeyPrefix-presence-${peer.deviceId}'),
              opacity: progress,
              child: Transform.scale(
                key: ValueKey(
                  '$peerKeyPrefix-presence-scale-${peer.deviceId}',
                ),
                scale: 0.86 + progress * 0.14,
                child: child,
              ),
            );
          },
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
