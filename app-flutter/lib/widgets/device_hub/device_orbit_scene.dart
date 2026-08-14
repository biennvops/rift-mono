import 'package:flutter/material.dart';

import '../../src/ui/motion.dart';
import 'device_orbit_background.dart';
import 'device_orbit_layout.dart';
import 'device_orbit_peer.dart';
import 'orbit_peer_layout_state.dart';
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
    this.onMembershipTransitionChanged,
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
  final ValueChanged<bool>? onMembershipTransitionChanged;
  final bool scanning;
  final bool animatePeerChanges;
  final String? emptyMessage;
  final Widget? emptyAction;
  final String? recentlyPairedDeviceId;
  final ValueChanged<String>? onRecentlyPairedAnimationCompleted;

  @override
  State<DeviceOrbitScene> createState() => _DeviceOrbitSceneState();
}

class _DeviceOrbitSceneState extends State<DeviceOrbitScene>
    with SingleTickerProviderStateMixin {
  static const _reflowDuration = Duration(milliseconds: 550);

  late final AnimationController _reflowController;
  Map<String, OrbitPeerLayoutState> _layoutStates = const {};
  Map<String, OrbitPeerPresentation> _transitionPeers = const {};
  DeviceOrbitGeometry? _lastGeometry;
  double? _frozenPhase;
  bool _isReflowing = false;

  @override
  void initState() {
    super.initState();
    _reflowController = AnimationController(
      vsync: this,
      duration: _reflowDuration,
    )..addStatusListener(_handleReflowStatus);
  }

  @override
  void didUpdateWidget(DeviceOrbitScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.peers.map((peer) => peer.deviceId).toSet();
    final newIds = widget.peers.map((peer) => peer.deviceId).toSet();

    for (final removedId in oldIds.difference(newIds)) {
      _releasePeerInteraction(removedId);
    }

    if (oldIds.length == newIds.length && oldIds.containsAll(newIds)) {
      if (_isReflowing) {
        final currentPeers = {
          for (final peer in widget.peers) peer.deviceId: peer,
        };
        _transitionPeers = {
          for (final entry in _transitionPeers.entries)
            entry.key: currentPeers[entry.key] ?? entry.value,
        };
      }
      return;
    }

    final geometry = _lastGeometry;
    if (!widget.animatePeerChanges ||
        RiftMotion.reducedMotionOf(context) ||
        geometry == null) {
      _clearReflow();
      return;
    }

    _startReflow(oldWidget.peers, geometry);
  }

  @override
  void dispose() {
    if (_isReflowing) {
      widget.onMembershipTransitionChanged?.call(false);
    }
    _reflowController.dispose();
    super.dispose();
  }

  List<OrbitPeerPresentation> _sortedPeers(
    Iterable<OrbitPeerPresentation> peers,
  ) {
    return peers.toList(growable: false)
      ..sort((left, right) => left.deviceId.compareTo(right.deviceId));
  }

  void _startReflow(
    List<OrbitPeerPresentation> previousPeers,
    DeviceOrbitGeometry geometry,
  ) {
    final previous = _sortedPeers(previousPeers);
    final next = _sortedPeers(widget.peers);
    final phase = _isReflowing ? _frozenPhase! : widget.phase.value;
    final currentProgress = _isReflowing
        ? RiftMotion.emphasis.transform(_reflowController.value)
        : 1.0;
    final visiblePeers = <String, OrbitPeerPresentation>{
      if (_isReflowing) ..._transitionPeers,
      for (final peer in previous) peer.deviceId: peer,
    };
    final currentCenters = <String, Offset>{};

    for (var index = 0; index < previous.length; index++) {
      final peer = previous[index];
      final activeState = _layoutStates[peer.deviceId];
      currentCenters[peer.deviceId] = activeState == null
          ? DeviceOrbitLayout.peerCenter(
              geometry: geometry,
              index: index,
              peerCount: previous.length,
              phase: phase,
            )
          : activeState.centerAt(currentProgress);
    }
    if (_isReflowing) {
      for (final entry in _layoutStates.entries) {
        currentCenters.putIfAbsent(
          entry.key,
          () => entry.value.centerAt(currentProgress),
        );
      }
    }

    final nextPeersById = {
      for (final peer in next) peer.deviceId: peer,
    };
    final states = <String, OrbitPeerLayoutState>{};
    for (var index = 0; index < next.length; index++) {
      final peer = next[index];
      final target = DeviceOrbitLayout.peerCenter(
        geometry: geometry,
        index: index,
        peerCount: next.length,
        phase: phase,
      );
      final current = currentCenters[peer.deviceId];
      states[peer.deviceId] = OrbitPeerLayoutState(
        deviceId: peer.deviceId,
        from: current ?? geometry.center + (target - geometry.center) * 0.72,
        to: target,
        entering: current == null,
        leaving: false,
      );
    }

    for (final entry in visiblePeers.entries) {
      if (nextPeersById.containsKey(entry.key)) continue;
      final current = currentCenters[entry.key];
      if (current == null) continue;
      final radialVector = current - geometry.center;
      final drift = radialVector.distance == 0
          ? Offset.zero
          : radialVector / radialVector.distance * 10;
      states[entry.key] = OrbitPeerLayoutState(
        deviceId: entry.key,
        from: current,
        to: current + drift,
        entering: false,
        leaving: true,
      );
    }

    _frozenPhase = phase;
    _layoutStates = states;
    _transitionPeers = {
      ...visiblePeers,
      ...nextPeersById,
    };
    if (!_isReflowing) {
      _isReflowing = true;
      widget.onMembershipTransitionChanged?.call(true);
    }
    _reflowController.forward(from: 0);
  }

  void _handleReflowStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_isReflowing || !mounted) {
      return;
    }
    setState(() {
      _isReflowing = false;
      _layoutStates = const {};
      _transitionPeers = const {};
      _frozenPhase = null;
    });
    widget.onMembershipTransitionChanged?.call(false);
  }

  void _clearReflow() {
    if (!_isReflowing && _layoutStates.isEmpty) return;
    _reflowController.stop();
    final wasReflowing = _isReflowing;
    _isReflowing = false;
    _layoutStates = const {};
    _transitionPeers = const {};
    _frozenPhase = null;
    if (wasReflowing) {
      widget.onMembershipTransitionChanged?.call(false);
    }
  }

  void _releasePeerInteraction(String deviceId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.peers.any((peer) => peer.deviceId == deviceId)) {
        return;
      }
      widget.onPeerInteractionChanged(deviceId, false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sortedPeers = _sortedPeers(widget.peers);
    return Focus(
      onFocusChange: widget.onSceneFocusChanged,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final geometry = DeviceOrbitLayout.calculate(size);
          _lastGeometry = geometry;
          final renderedPeers = _isReflowing
              ? _sortedPeers(_transitionPeers.values)
              : sortedPeers;
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
                for (var index = 0; index < renderedPeers.length; index++)
                  _OrbitPositionedPeer(
                    key: ValueKey(
                      '${widget.peerKeyPrefix}-slot-${renderedPeers[index].deviceId}',
                    ),
                    animation: _isReflowing ? _reflowController : widget.phase,
                    geometry: geometry,
                    index: index,
                    peerCount: renderedPeers.length,
                    phase: _isReflowing
                        ? _frozenPhase ?? widget.phase.value
                        : null,
                    layoutState: _layoutStates[renderedPeers[index].deviceId],
                    peer: renderedPeers[index],
                    peerKeyPrefix: widget.peerKeyPrefix,
                    peerSemanticRole: widget.peerSemanticRole,
                    onTap: () => widget.onPeerSelected(renderedPeers[index]),
                    onInteractionChanged: (interacting) =>
                        widget.onPeerInteractionChanged(
                      renderedPeers[index].deviceId,
                      interacting,
                    ),
                    isNewlyPaired: renderedPeers[index].deviceId ==
                        widget.recentlyPairedDeviceId,
                    onPairingAnimationCompleted:
                        widget.onRecentlyPairedAnimationCompleted,
                  ),
                if (renderedPeers.isEmpty && widget.emptyMessage != null)
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

class _OrbitPositionedPeer extends StatelessWidget {
  const _OrbitPositionedPeer({
    super.key,
    required this.animation,
    required this.geometry,
    required this.index,
    required this.peerCount,
    required this.phase,
    required this.layoutState,
    required this.peer,
    required this.peerKeyPrefix,
    required this.peerSemanticRole,
    required this.onTap,
    required this.onInteractionChanged,
    required this.isNewlyPaired,
    required this.onPairingAnimationCompleted,
  });

  final Animation<double> animation;
  final DeviceOrbitGeometry geometry;
  final int index;
  final int peerCount;
  final double? phase;
  final OrbitPeerLayoutState? layoutState;
  final OrbitPeerPresentation peer;
  final String peerKeyPrefix;
  final String peerSemanticRole;
  final VoidCallback onTap;
  final ValueChanged<bool> onInteractionChanged;
  final bool isNewlyPaired;
  final ValueChanged<String>? onPairingAnimationCompleted;

  @override
  Widget build(BuildContext context) {
    final state = layoutState;
    final present = state?.leaving != true;
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
        animation: animation,
        child: peerContent,
        builder: (context, child) {
          final progress = state == null
              ? 1.0
              : RiftMotion.emphasis.transform(animation.value);
          final center = state?.centerAt(progress) ??
              DeviceOrbitLayout.peerCenter(
                geometry: geometry,
                index: index,
                peerCount: peerCount,
                phase: phase ?? animation.value,
              );
          final opacity = state?.leaving == true
              ? 1 - progress
              : (state?.entering == true ? progress : 1.0);
          final scale = state?.leaving == true
              ? 1 - progress * 0.22
              : (state?.entering == true ? _entryScale(progress) : 1.0);
          return Stack(
            children: [
              Positioned(
                left: center.dx - geometry.peerSize / 2,
                top: center.dy - geometry.peerSize / 2,
                child: Opacity(
                  key: ValueKey('$peerKeyPrefix-presence-${peer.deviceId}'),
                  opacity: opacity,
                  child: Transform.scale(
                    key: ValueKey(
                      '$peerKeyPrefix-presence-scale-${peer.deviceId}',
                    ),
                    scale: scale,
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double _entryScale(double progress) {
    if (progress < 0.82) {
      return 0.65 + (1.03 - 0.65) * (progress / 0.82);
    }
    return 1.03 - 0.03 * ((progress - 0.82) / 0.18);
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
