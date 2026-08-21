import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/media_playback/playback_presentation.dart';
import '../animated_accent.dart';
import '../device_hub/device_platform_presentation.dart';
import '../device_hub/orbit_peer_presentation.dart';
import 'device_core.dart';
import 'device_focus_background.dart';
import 'device_focus_connector_painter.dart';
import 'device_focus_layout.dart';
import 'device_focus_node.dart';
import 'device_focus_node_panel.dart';
import '../../src/ui/motion.dart';

typedef DeviceFocusCopyCallback = void Function(String text, String message);

class DeviceFocusView extends StatefulWidget {
  const DeviceFocusView({
    super.key,
    required this.presentation,
    required this.fingerprint,
    required this.protocolVersion,
    required this.osVersion,
    required this.pairedAt,
    required this.lastSeenAt,
    required this.capabilities,
    required this.onClose,
    required this.onCopy,
    this.onRevokeTrust,
    this.onOpenClipboardActivity,
    this.onSendFile,
    this.onViewTransferActivity,
    this.deviceStatus,
    this.mediaPlayback,
  });

  final OrbitPeerPresentation presentation;
  final String fingerprint;
  final String protocolVersion;
  final String osVersion;
  final String pairedAt;
  final String lastSeenAt;
  final List<String> capabilities;
  final Map<String, dynamic>? deviceStatus;
  final MediaPlaybackPresentation? mediaPlayback;
  final VoidCallback? onOpenClipboardActivity;
  final VoidCallback? onSendFile;
  final VoidCallback? onViewTransferActivity;
  final VoidCallback onClose;
  final VoidCallback? onRevokeTrust;
  final DeviceFocusCopyCallback onCopy;

  String get deviceId => presentation.deviceId;
  String get displayName => presentation.displayName;
  String get platform => presentation.platform;
  bool get isOnline => presentation.isOnline;
  bool get isSelf => presentation.statusKind == OrbitPeerStatusKind.local;

  @override
  State<DeviceFocusView> createState() => _DeviceFocusViewState();
}

class _DeviceFocusViewState extends State<DeviceFocusView>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _onlineController;
  late final AnimationController _wakeController;
  late final AnimationController _panelController;
  late final Map<DeviceFocusNodeKind, FocusNode> _nodeFocusNodes;
  bool _reducedMotion = false;
  DeviceFocusNodeKind? _activeNode;
  DeviceFocusNodeKind? _closingNode;
  DeviceFocusNodeKind? _hoveredNode;

  MediaPlaybackPresentation? get _liveMediaPlayback =>
      widget.presentation.activity == OrbitPeerActivity.none
          ? null
          : widget.mediaPlayback;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: RiftMotion.scene,
    )..forward();
    _onlineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: widget.isOnline ? 1 : 0,
    );
    _wakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 560),
    );
    _panelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 300),
    )..addStatusListener(_handlePanelStatus);
    _nodeFocusNodes = {
      for (final kind in DeviceFocusNodeKind.values) kind: FocusNode(),
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = RiftMotion.reducedMotionOf(context);
    if (reducedMotion == _reducedMotion && _entranceController.value != 0) {
      return;
    }
    _reducedMotion = reducedMotion;
    if (reducedMotion) {
      _entranceController.stop();
      _entranceController.value = 1;
      _onlineController.value = widget.isOnline ? 1 : 0;
      _wakeController.value = 0;
    } else if (_entranceController.value < 1 &&
        !_entranceController.isAnimating) {
      _entranceController.forward();
    }
  }

  @override
  void didUpdateWidget(DeviceFocusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId) {
      _activeNode = null;
      _closingNode = null;
      _hoveredNode = null;
      _panelController.value = 0;
      if (_reducedMotion) {
        _entranceController.value = 1;
      } else {
        _entranceController.forward(from: 0);
      }
    } else if ((widget.deviceStatus == null &&
            _activeNode == DeviceFocusNodeKind.power) ||
        (!widget.isSelf &&
            !widget.capabilities.contains('media.playback') &&
            _activeNode == DeviceFocusNodeKind.media)) {
      _activeNode = null;
      _closingNode = null;
      _panelController.value = 0;
    }
    if (oldWidget.isOnline != widget.isOnline) {
      if (_reducedMotion) {
        _onlineController.value = widget.isOnline ? 1 : 0;
      } else {
        _onlineController.animateTo(
          widget.isOnline ? 1 : 0,
          curve: Curves.easeInOutCubic,
        );
      }
      if (widget.isOnline && !_reducedMotion) {
        _wakeController.forward(from: 0);
      } else {
        _wakeController.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _onlineController.dispose();
    _wakeController.dispose();
    _panelController.dispose();
    for (final focusNode in _nodeFocusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  void _handlePanelStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed ||
        _activeNode == null ||
        !mounted) {
      return;
    }
    final focusKind = _closingNode ?? _activeNode;
    setState(() {
      _activeNode = null;
      _closingNode = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusKind != null) {
        _nodeFocusNodes[focusKind]?.requestFocus();
      }
    });
  }

  void _openNode(DeviceFocusNodeKind kind) {
    if (_activeNode == kind) {
      _closePanel();
      return;
    }
    setState(() {
      _activeNode = kind;
      _closingNode = null;
    });
    _panelController.duration =
        _reducedMotion ? RiftMotion.fast : const Duration(milliseconds: 380);
    _panelController.reverseDuration =
        _reducedMotion ? RiftMotion.fast : const Duration(milliseconds: 300);
    _panelController.forward(from: 0);
  }

  void _closePanel() {
    if (_activeNode == null) return;
    _closingNode = _activeNode;
    _panelController.reverse();
  }

  void _handleEscape() {
    if (_activeNode != null) {
      _closePanel();
    } else {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetAccent = widget.presentation.accentColor ??
        Theme.of(context).colorScheme.primary;
    return AnimatedAccent(
      color: targetAccent,
      builder: _buildView,
    );
  }

  Widget _buildView(BuildContext context, Color accent) {
    final theme = Theme.of(context);
    final nodes = _buildNodes(accent);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('device-focus-view'),
          backgroundColor: theme.colorScheme.surface,
          body: SafeArea(
            child: Column(
              children: [
                _buildHeader(theme),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final sceneSize = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      final geometry = DeviceFocusLayout.calculate(
                        sceneSize,
                        nodes.map((node) => node.kind),
                      );
                      return ClipRect(
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _activeNode == null ? null : _closePanel,
                                child: DeviceFocusBackground(
                                  geometry: geometry,
                                  entrance: _entranceController,
                                  online: _onlineController,
                                  accentColor: accent,
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    painter: DeviceFocusConnectorPainter(
                                      geometry: geometry,
                                      entrance: _entranceController,
                                      online: _onlineController,
                                      color: accent,
                                      activeNode: _activeNode,
                                      hoveredNode: _hoveredNode,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _positionCore(geometry, accent),
                            for (var index = 0; index < nodes.length; index++)
                              _positionNode(
                                geometry: geometry,
                                data: nodes[index],
                                index: index,
                              ),
                            _positionPanel(sceneSize, geometry, accent),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final platformLabel = devicePlatformLabel(widget.platform);
    final presentation = widget.presentation;
    final identityDetails = <String>[
      'Device Focus',
      if (platformLabel != null) platformLabel,
      if (widget.osVersion.isNotEmpty && widget.osVersion != 'Unavailable')
        widget.osVersion,
      presentation.statusLabel!,
      if (presentation.powerLabel case final powerLabel?) powerLabel,
      if (presentation.mediaStateLabel case final mediaState?) mediaState,
      if (widget.protocolVersion.isNotEmpty) 'Rift ${widget.protocolVersion}',
      if (!widget.isSelf &&
          widget.lastSeenAt.isNotEmpty &&
          widget.lastSeenAt != 'Unavailable')
        'Last seen ${widget.lastSeenAt}',
    ];
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.hub_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  identityDetails.join(' · '),
                  key: const ValueKey('device-focus-summary'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  widget.deviceId,
                  key: const ValueKey('device-focus-device-id'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFamily: 'JetBrains Mono',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('device-focus-close'),
            tooltip: 'Close device details',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Positioned _positionCore(
    DeviceFocusGeometry geometry,
    Color accent,
  ) {
    Widget core = DeviceCore(
      size: geometry.coreSize,
      displayName: widget.displayName,
      platformIcon: devicePlatformIcon(widget.platform),
      isOnline: widget.isOnline,
      entrance: _entranceController,
      online: _onlineController,
      wake: _wakeController,
      statusLabel: widget.presentation.statusLabel,
      semanticLabel: widget.presentation.semanticDescription(),
      accentColor: accent,
      mediaActivity: widget.presentation.activity,
    );
    if (widget.presentation.accentColor != null) {
      core = KeyedSubtree(
        key: const ValueKey('device-focus-media-accented'),
        child: core,
      );
    }
    return Positioned(
      left: geometry.center.dx - geometry.coreSize / 2,
      top: geometry.center.dy - geometry.coreSize / 2,
      child: core,
    );
  }

  Widget _positionNode({
    required DeviceFocusGeometry geometry,
    required _DeviceFocusNodeData data,
    required int index,
  }) {
    final center = geometry.nodeCenters[data.kind]!;
    final vector = geometry.center - center;
    final entranceOffset =
        vector.distance == 0 ? Offset.zero : vector / vector.distance * 18;
    Widget child = DeviceFocusNode(
      key: ValueKey('device-focus-node-${data.kind.name}'),
      kind: data.kind,
      icon: data.icon,
      value: data.value,
      label: data.label,
      size: geometry.nodeSize,
      isSelected: _activeNode == data.kind,
      entrance: _entranceController,
      entranceIndex: index,
      entranceOffset: entranceOffset,
      focusNode: _nodeFocusNodes[data.kind],
      onTap: () => _openNode(data.kind),
      onInteractionChanged: (isInteracting) {
        setState(() {
          if (isInteracting) {
            _hoveredNode = data.kind;
          } else if (_hoveredNode == data.kind) {
            _hoveredNode = null;
          }
        });
      },
      accentColor: data.accentColor,
    );
    if (data.kind == DeviceFocusNodeKind.media && _liveMediaPlayback != null) {
      child = KeyedSubtree(
        key: ValueKey(
          'device-focus-media-${_liveMediaPlayback!.playbackState}',
        ),
        child: child,
      );
    }
    return Positioned(
      left: center.dx - geometry.nodeSize.width / 2,
      top: center.dy - geometry.nodeSize.height / 2,
      child: child,
    );
  }

  Positioned _positionPanel(
    Size sceneSize,
    DeviceFocusGeometry geometry,
    Color accent,
  ) {
    final activeNode = _activeNode;
    if (activeNode == null) {
      return const Positioned.fill(
        child: SizedBox.shrink(
          key: ValueKey('device-focus-panel-empty'),
        ),
      );
    }

    final sourceCenter = geometry.nodeCenters[activeNode] ?? geometry.center;
    final sourceRect = Rect.fromCenter(
      center: sourceCenter,
      width: geometry.nodeSize.width,
      height: geometry.nodeSize.height,
    );
    final targetWidth = math.min(520.0, sceneSize.width - 32).toDouble();
    final preferredHeight =
        (sceneSize.height * 0.72).clamp(260.0, 500.0).toDouble();
    final targetHeight =
        math.min(preferredHeight, sceneSize.height - 32).toDouble();
    final targetRect = Rect.fromCenter(
      center: Offset(sceneSize.width / 2, sceneSize.height / 2),
      width: targetWidth,
      height: targetHeight,
    );

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _panelController,
        builder: (context, child) {
          final value = _panelController.value;
          final transformProgress = _reducedMotion
              ? 1.0
              : const Interval(0, 0.65, curve: RiftMotion.move)
                  .transform(value);
          final contentOpacity =
              const Interval(0.35, 1, curve: RiftMotion.enter).transform(value);
          final panelRect =
              Rect.lerp(sourceRect, targetRect, transformProgress)!;
          final borderRadius = 12 + transformProgress * 4;
          final elevation = transformProgress * 10;
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: value == 0,
                  child: GestureDetector(
                    key: const ValueKey('device-focus-panel-scrim'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _closePanel,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: value * 0.14),
                    ),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: panelRect,
                child: SizedBox(
                  key: ValueKey('device-focus-panel-${activeNode.name}'),
                  child: DeviceFocusNodePanel(
                    kind: activeNode,
                    title: _panelTitle(activeNode),
                    icon: _nodeIcon(activeNode),
                    rows: _panelRows(activeNode),
                    body: _panelBody(activeNode),
                    maxHeight: panelRect.height,
                    onClose: _closePanel,
                    footer: _panelFooter(activeNode),
                    accentColor: accent,
                    elevation: elevation,
                    borderRadius: borderRadius,
                    contentOpacity: contentOpacity,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<_DeviceFocusNodeData> _buildNodes(Color accent) {
    final featureCount = widget.capabilities.length;
    return [
      if (widget.deviceStatus != null)
        _DeviceFocusNodeData(
          kind: DeviceFocusNodeKind.power,
          icon: _nodeIcon(DeviceFocusNodeKind.power),
          value: _powerSummary(widget.deviceStatus!),
          label: 'Power',
        ),
      if (widget.isSelf || _hasCapability('media.playback'))
        _DeviceFocusNodeData(
          kind: DeviceFocusNodeKind.media,
          icon: _nodeIcon(DeviceFocusNodeKind.media),
          value: _liveMediaPlayback?.displayTitle ?? 'Nothing playing',
          label: widget.presentation.mediaStateLabel ?? 'Media',
          accentColor: accent,
        ),
      _DeviceFocusNodeData(
        kind: DeviceFocusNodeKind.features,
        icon: _nodeIcon(DeviceFocusNodeKind.features),
        value: '$featureCount available',
        label: 'Features',
      ),
      if (!widget.isSelf)
        _DeviceFocusNodeData(
          kind: DeviceFocusNodeKind.security,
          icon: _nodeIcon(DeviceFocusNodeKind.security),
          value: 'Trusted',
          label: 'Security',
        ),
    ];
  }

  bool _hasCapability(String capability) =>
      widget.capabilities.contains(capability);

  String _panelTitle(DeviceFocusNodeKind kind) => switch (kind) {
        DeviceFocusNodeKind.power => 'Power status',
        DeviceFocusNodeKind.media => 'Media playback',
        DeviceFocusNodeKind.features => 'Features',
        DeviceFocusNodeKind.security => 'Security',
      };

  IconData _nodeIcon(DeviceFocusNodeKind kind) => switch (kind) {
        DeviceFocusNodeKind.power => Icons.battery_charging_full,
        DeviceFocusNodeKind.media => Icons.graphic_eq,
        DeviceFocusNodeKind.features => Icons.extension_outlined,
        DeviceFocusNodeKind.security => Icons.verified_user_outlined,
      };

  List<DeviceFocusPanelRow> _panelRows(DeviceFocusNodeKind kind) {
    return switch (kind) {
      DeviceFocusNodeKind.power => _powerRows(widget.deviceStatus!),
      DeviceFocusNodeKind.media => const [],
      DeviceFocusNodeKind.features => const [],
      DeviceFocusNodeKind.security => [
          DeviceFocusPanelRow(
            label: 'Trust established',
            value: widget.pairedAt,
          ),
          DeviceFocusPanelRow(
            label: 'Fingerprint',
            value: widget.fingerprint,
            onCopy: () => widget.onCopy(
              widget.fingerprint,
              'Fingerprint copied to clipboard',
            ),
          ),
        ],
    };
  }

  Widget? _panelBody(DeviceFocusNodeKind kind) => switch (kind) {
        DeviceFocusNodeKind.media => _buildMediaPanel(),
        DeviceFocusNodeKind.features => _buildFeaturesPanel(),
        _ => null,
      };

  Widget _buildMediaPanel() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final media = _liveMediaPlayback;
    final hasPosition = media?.positionMs != null &&
        media?.durationMs != null &&
        media!.durationMs! > 0;
    final progress = hasPosition
        ? (media.positionMs! / media.durationMs!).clamp(0.0, 1.0)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildMediaArtworkSlot(),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    media?.displayTitle ?? 'Nothing playing',
                    key: const ValueKey('device-focus-media-title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (media != null && media.artist.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      media.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                  if (media != null && media.album.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      media.album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    media?.stateLabel ?? 'Nothing playing',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (hasPosition) ...[
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatPlaybackTime(media.positionMs!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                _formatPlaybackTime(media.durationMs!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            key: const ValueKey('device-focus-media-progress'),
            value: progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(999),
          ),
        ],
        if (media != null && media.application.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                Icons.apps_outlined,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  media.application,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMediaArtworkSlot() {
    final theme = Theme.of(context);
    final media = _liveMediaPlayback;
    final bytes = media?.artworkBytes;
    final identity = media?.artworkIdentity;
    final artwork = bytes == null || identity == null
        ? Container(
            key: const ValueKey('device-focus-media-artwork-placeholder'),
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Icon(
              Icons.graphic_eq,
              size: 38,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        : ClipRRect(
            key: ValueKey('device-focus-media-artwork-$identity'),
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              width: 104,
              height: 104,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stackTrace) => Container(
                width: 104,
                height: 104,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.graphic_eq,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
    return SizedBox.square(
      dimension: 104,
      child: AnimatedSwitcher(
        duration: RiftMotion.durationOf(context, RiftMotion.normal),
        switchInCurve: RiftMotion.enter,
        switchOutCurve: RiftMotion.exit,
        child: artwork,
      ),
    );
  }

  String _formatPlaybackTime(int milliseconds) {
    final totalSeconds = milliseconds.clamp(0, 1 << 31) ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  List<DeviceFocusPanelRow> _powerRows(Map<String, dynamic> status) {
    final rows = <DeviceFocusPanelRow>[];
    final batteryPresent = status['batteryPresent'];
    final batteryPercent = status['batteryPercent'];
    if (batteryPresent == false) {
      rows.add(
          const DeviceFocusPanelRow(label: 'Battery', value: 'No battery'));
    } else if (batteryPercent is num) {
      rows.add(
        DeviceFocusPanelRow(
          label: 'Battery',
          value: '${batteryPercent.toInt()}%',
        ),
      );
    }
    final chargingState = status['chargingState']?.toString();
    if (chargingState != null) {
      rows.add(
        DeviceFocusPanelRow(
          label: 'Charging state',
          value: _formatChargingState(chargingState),
        ),
      );
    }
    final powerSource = status['powerSource']?.toString();
    if (powerSource != null) {
      rows.add(
        DeviceFocusPanelRow(
          label: 'Power source',
          value: _formatPowerSource(powerSource),
        ),
      );
    }
    if (status['lowPowerMode'] is bool) {
      rows.add(
        DeviceFocusPanelRow(
          label: 'Low Power Mode',
          value: status['lowPowerMode'] == true ? 'On' : 'Off',
        ),
      );
    }
    final observedAt = _formatTimestamp(status['observedAt']?.toString());
    rows.add(
      DeviceFocusPanelRow(
        label: 'Status',
        value: status['isStale'] == true ? 'Stale · $observedAt' : observedAt,
      ),
    );
    return rows;
  }

  Widget _buildFeaturesPanel() {
    final capabilities = widget.capabilities;
    if (capabilities.isEmpty) {
      return Text(
        'No negotiated features reported.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < capabilities.length; index++) ...[
          _buildFeatureRow(capabilities[index]),
          if (index != capabilities.length - 1)
            Divider(
              height: 20,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
        ],
      ],
    );
  }

  Widget _buildFeatureRow(String capability) {
    final theme = Theme.of(context);
    final actions = _featureActions(capability);
    return Container(
      key: ValueKey('device-focus-feature-$capability'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _featureIcon(capability),
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _formatCapability(capability),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                'Available',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }

  List<Widget> _featureActions(String capability) => switch (capability) {
        'clipboard.offer_fetch' => [
            FilledButton.icon(
              key: const ValueKey('device-focus-open-clipboard'),
              onPressed: widget.onOpenClipboardActivity,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open Clipboard'),
            ),
          ],
        'file.transfer' => [
            FilledButton.icon(
              key: const ValueKey('device-focus-send-file'),
              onPressed: widget.onSendFile,
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('Send File'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('device-focus-view-transfers'),
              onPressed: widget.onViewTransferActivity,
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text('Transfers'),
            ),
          ],
        _ => const [],
      };

  IconData _featureIcon(String capability) => switch (capability) {
        'clipboard.offer_fetch' => Icons.content_paste_outlined,
        'device.status' => Icons.monitor_heart_outlined,
        'file.transfer' => Icons.folder_outlined,
        'media.playback' => Icons.graphic_eq,
        'notification.sync' => Icons.notifications_outlined,
        _ => Icons.extension_outlined,
      };

  Widget? _panelFooter(DeviceFocusNodeKind kind) {
    final colors = Theme.of(context).colorScheme;
    final onRevokeTrust = widget.onRevokeTrust;
    if (kind != DeviceFocusNodeKind.security || onRevokeTrust == null) {
      return null;
    }
    return OutlinedButton.icon(
      key: const ValueKey('device-focus-revoke-trust'),
      onPressed: onRevokeTrust,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.error,
        side: BorderSide(color: colors.error),
        minimumSize: const Size(double.infinity, 44),
      ),
      icon: const Icon(Icons.delete_outline, size: 19),
      label: const Text('Revoke Trust'),
    );
  }

  String _powerSummary(Map<String, dynamic> status) {
    final livePower = widget.presentation.powerLabel;
    if (livePower != null) return livePower;
    if (status['isStale'] == true || !widget.isOnline) return 'Status stale';
    if (status['batteryPresent'] == false) return 'No battery';
    return 'Status';
  }

  String _formatChargingState(String value) => switch (value) {
        'charging' => 'Charging',
        'discharging' => 'Discharging',
        'full' => 'Full',
        'notCharging' => 'Not charging',
        _ => 'Unknown',
      };

  String _formatPowerSource(String value) => switch (value) {
        'ac' => 'AC power',
        'usb' => 'USB power',
        'battery' => 'Battery',
        _ => 'Unknown',
      };

  String _formatTimestamp(String? raw) {
    if (raw == null || raw.isEmpty) return 'Unavailable';
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    final yyyy = parsed.year.toString().padLeft(4, '0');
    final mm = parsed.month.toString().padLeft(2, '0');
    final dd = parsed.day.toString().padLeft(2, '0');
    final hh = parsed.hour.toString().padLeft(2, '0');
    final min = parsed.minute.toString().padLeft(2, '0');
    final sec = parsed.second.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$min:$sec';
  }

  String _formatCapability(String capability) => switch (capability) {
        'clipboard.offer_fetch' => 'Clipboard sync',
        'device.status' => 'Device status',
        'file.transfer' => 'File transfer',
        'media.playback' => 'Media playback',
        'notification.sync' => 'Notification sync',
        'operation.lifecycle' => 'Operations',
        'presence.basic' => 'Presence',
        'security.event_log' => 'Security event log',
        _ => capability,
      };
}

class _DeviceFocusNodeData {
  const _DeviceFocusNodeData({
    required this.kind,
    required this.icon,
    required this.value,
    required this.label,
    this.accentColor,
  });

  final DeviceFocusNodeKind kind;
  final IconData icon;
  final String value;
  final String label;
  final Color? accentColor;
}
