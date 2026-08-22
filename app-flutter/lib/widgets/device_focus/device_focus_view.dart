import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/media_playback/playback_presentation.dart';
import '../animated_accent.dart';
import '../device_hub/device_platform_presentation.dart';
import '../device_hub/orbit_peer_presentation.dart';
import 'device_core.dart';
import 'device_detail_content.dart';
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
    return DeviceMediaDetailsView(media: _liveMediaPlayback);
  }

  List<DeviceFocusPanelRow> _powerRows(Map<String, dynamic> status) {
    final details = DevicePowerDetails.fromStatus(
      status,
      isOnline: widget.isOnline,
    );
    return details.rows
        .map(
          (row) => DeviceFocusPanelRow(
            label: row.label,
            value: row.value,
          ),
        )
        .toList(growable: false);
  }

  Widget _buildFeaturesPanel() {
    return DeviceFeaturesView(
      capabilities: widget.capabilities,
      onOpenClipboardActivity: widget.onOpenClipboardActivity,
      onSendFile: widget.onSendFile,
      onViewTransferActivity: widget.onViewTransferActivity,
    );
  }

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
    return DevicePowerDetails.fromStatus(
      status,
      isOnline: widget.isOnline,
    ).summary(widget.presentation.powerLabel);
  }
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
