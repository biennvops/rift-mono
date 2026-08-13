import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'device_core.dart';
import 'device_focus_background.dart';
import 'device_focus_connector_painter.dart';
import 'device_focus_layout.dart';
import 'device_focus_node.dart';
import 'device_focus_node_panel.dart';

typedef DeviceFocusCopyCallback = void Function(String text, String message);

class DeviceFocusView extends StatefulWidget {
  const DeviceFocusView({
    super.key,
    required this.deviceId,
    required this.displayName,
    required this.fingerprint,
    required this.protocolVersion,
    required this.platform,
    required this.osVersion,
    required this.pairedAt,
    required this.lastSeenAt,
    required this.capabilities,
    required this.isOnline,
    required this.onClose,
    required this.onRevokeTrust,
    required this.onCopy,
    this.deviceStatus,
  });

  final String deviceId;
  final String displayName;
  final String fingerprint;
  final String protocolVersion;
  final String platform;
  final String osVersion;
  final String pairedAt;
  final String lastSeenAt;
  final List<String> capabilities;
  final Map<String, dynamic>? deviceStatus;
  final bool isOnline;
  final VoidCallback onClose;
  final VoidCallback onRevokeTrust;
  final DeviceFocusCopyCallback onCopy;

  @override
  State<DeviceFocusView> createState() => _DeviceFocusViewState();
}

class _DeviceFocusViewState extends State<DeviceFocusView>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _onlineController;
  late final AnimationController _wakeController;
  DeviceFocusNodeKind? _activeNode;
  DeviceFocusNodeKind? _hoveredNode;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
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
  }

  @override
  void didUpdateWidget(DeviceFocusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId) {
      _activeNode = null;
      _hoveredNode = null;
      _entranceController.forward(from: 0);
    } else if (widget.deviceStatus == null &&
        _activeNode == DeviceFocusNodeKind.power) {
      _activeNode = null;
    }
    if (oldWidget.isOnline != widget.isOnline) {
      _onlineController.animateTo(
        widget.isOnline ? 1 : 0,
        curve: Curves.easeInOutCubic,
      );
      if (widget.isOnline) {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = _buildNodes();
    return Scaffold(
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
                            onTap: _activeNode == null
                                ? null
                                : () => setState(() => _activeNode = null),
                            child: DeviceFocusBackground(
                              geometry: geometry,
                              entrance: _entranceController,
                              online: _onlineController,
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
                                  color: theme.colorScheme.primary,
                                  activeNode: _activeNode,
                                  hoveredNode: _hoveredNode,
                                ),
                              ),
                            ),
                          ),
                        ),
                        _positionCore(geometry),
                        for (var index = 0; index < nodes.length; index++)
                          _positionNode(
                            geometry: geometry,
                            data: nodes[index],
                            index: index,
                          ),
                        _positionPanel(sceneSize, geometry),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 18),
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
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Device Focus',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Trusted peer overview',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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

  Positioned _positionCore(DeviceFocusGeometry geometry) {
    return Positioned(
      left: geometry.center.dx - geometry.coreSize / 2,
      top: geometry.center.dy - geometry.coreSize / 2,
      child: DeviceCore(
        size: geometry.coreSize,
        displayName: widget.displayName,
        platformIcon: _platformIcon(widget.platform),
        isOnline: widget.isOnline,
        entrance: _entranceController,
        online: _onlineController,
        wake: _wakeController,
      ),
    );
  }

  Positioned _positionNode({
    required DeviceFocusGeometry geometry,
    required _DeviceFocusNodeData data,
    required int index,
  }) {
    final center = geometry.nodeCenters[data.kind]!;
    final vector = geometry.center - center;
    final entranceOffset =
        vector.distance == 0 ? Offset.zero : vector / vector.distance * 18;
    return Positioned(
      left: center.dx - geometry.nodeSize.width / 2,
      top: center.dy - geometry.nodeSize.height / 2,
      child: DeviceFocusNode(
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
        onTap: () {
          setState(() {
            _activeNode = _activeNode == data.kind ? null : data.kind;
          });
        },
        onInteractionChanged: (isInteracting) {
          setState(() {
            if (isInteracting) {
              _hoveredNode = data.kind;
            } else if (_hoveredNode == data.kind) {
              _hoveredNode = null;
            }
          });
        },
      ),
    );
  }

  Positioned _positionPanel(
    Size sceneSize,
    DeviceFocusGeometry geometry,
  ) {
    const panelBottom = 16.0;
    const nodeGap = 12.0;
    final panelWidth = math.min(400.0, sceneSize.width - 32).toDouble();
    final lowestNodeBottom = geometry.nodeCenters.values.fold<double>(
      0,
      (lowest, center) => math.max(
        lowest,
        center.dy + geometry.nodeSize.height / 2,
      ),
    );
    final availablePanelHeight =
        sceneSize.height - panelBottom - nodeGap - lowestNodeBottom;
    final preferredPanelHeight =
        math.min(340.0, math.max(220.0, sceneSize.height * 0.48)).toDouble();
    final panelHeight = math
        .min(
          preferredPanelHeight,
          math.max(96.0, availablePanelHeight),
        )
        .toDouble();
    final activeNode = _activeNode;
    return Positioned(
      left: (sceneSize.width - panelWidth) / 2,
      bottom: panelBottom,
      width: panelWidth,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.97, end: 1.0).animate(animation),
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          );
        },
        child: activeNode == null
            ? const SizedBox.shrink(
                key: ValueKey('device-focus-panel-empty'),
              )
            : SizedBox(
                key: ValueKey('device-focus-panel-${activeNode.name}'),
                child: DeviceFocusNodePanel(
                  kind: activeNode,
                  title: _panelTitle(activeNode),
                  icon: _nodeIcon(activeNode),
                  rows: _panelRows(activeNode),
                  maxHeight: panelHeight,
                  onClose: () => setState(() => _activeNode = null),
                  footer: _panelFooter(activeNode),
                ),
              ),
      ),
    );
  }

  List<_DeviceFocusNodeData> _buildNodes() {
    final capabilities = widget.capabilities.length;
    return [
      if (widget.deviceStatus != null)
        _DeviceFocusNodeData(
          kind: DeviceFocusNodeKind.power,
          icon: _nodeIcon(DeviceFocusNodeKind.power),
          value: _powerSummary(widget.deviceStatus!),
          label: 'Power',
        ),
      _DeviceFocusNodeData(
        kind: DeviceFocusNodeKind.security,
        icon: _nodeIcon(DeviceFocusNodeKind.security),
        value: 'Trusted',
        label: 'Security',
      ),
      _DeviceFocusNodeData(
        kind: DeviceFocusNodeKind.identity,
        icon: _nodeIcon(DeviceFocusNodeKind.identity),
        value: widget.platform.toUpperCase(),
        label: 'Identity',
      ),
      _DeviceFocusNodeData(
        kind: DeviceFocusNodeKind.capabilities,
        icon: _nodeIcon(DeviceFocusNodeKind.capabilities),
        value: '$capabilities available',
        label: 'Capabilities',
      ),
      _DeviceFocusNodeData(
        kind: DeviceFocusNodeKind.info,
        icon: _nodeIcon(DeviceFocusNodeKind.info),
        value: widget.isOnline ? 'Online' : 'Offline',
        label: 'Info',
      ),
    ];
  }

  String _panelTitle(DeviceFocusNodeKind kind) => switch (kind) {
        DeviceFocusNodeKind.power => 'Power status',
        DeviceFocusNodeKind.security => 'Security',
        DeviceFocusNodeKind.identity => 'Identity',
        DeviceFocusNodeKind.capabilities => 'Capabilities',
        DeviceFocusNodeKind.info => 'Device information',
      };

  IconData _nodeIcon(DeviceFocusNodeKind kind) => switch (kind) {
        DeviceFocusNodeKind.power => Icons.battery_charging_full,
        DeviceFocusNodeKind.security => Icons.verified_user_outlined,
        DeviceFocusNodeKind.identity => Icons.badge_outlined,
        DeviceFocusNodeKind.capabilities => Icons.extension_outlined,
        DeviceFocusNodeKind.info => Icons.info_outline,
      };

  List<DeviceFocusPanelRow> _panelRows(DeviceFocusNodeKind kind) {
    return switch (kind) {
      DeviceFocusNodeKind.power => _powerRows(widget.deviceStatus!),
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
      DeviceFocusNodeKind.identity => [
          DeviceFocusPanelRow(
            label: 'Device ID',
            value: widget.deviceId,
            onCopy: () => widget.onCopy(
              widget.deviceId,
              'Device ID copied to clipboard',
            ),
          ),
          DeviceFocusPanelRow(
            label: 'Fingerprint',
            value: widget.fingerprint,
            onCopy: () => widget.onCopy(
              widget.fingerprint,
              'Fingerprint copied to clipboard',
            ),
          ),
          DeviceFocusPanelRow(
            label: 'Platform',
            value: widget.platform.toUpperCase(),
          ),
          DeviceFocusPanelRow(label: 'OS version', value: widget.osVersion),
          DeviceFocusPanelRow(
            label: 'Rift client version',
            value: widget.protocolVersion,
          ),
        ],
      DeviceFocusNodeKind.capabilities => _capabilityRows(),
      DeviceFocusNodeKind.info => [
          DeviceFocusPanelRow(
            label: 'Connection',
            value: widget.isOnline ? 'Online' : 'Offline',
          ),
          DeviceFocusPanelRow(label: 'Last seen', value: widget.lastSeenAt),
          DeviceFocusPanelRow(
            label: 'Status freshness',
            value: widget.deviceStatus == null
                ? 'Unavailable'
                : (widget.deviceStatus!['isStale'] == true
                    ? 'Stale'
                    : 'Current'),
          ),
        ],
    };
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

  List<DeviceFocusPanelRow> _capabilityRows() {
    if (widget.capabilities.isEmpty) {
      return const [
        DeviceFocusPanelRow(
          label: 'Negotiated capabilities',
          value: 'None reported',
        ),
      ];
    }
    return widget.capabilities
        .map(
          (capability) => DeviceFocusPanelRow(
            label: _formatCapability(capability),
            value: 'Available',
          ),
        )
        .toList(growable: false);
  }

  Widget? _panelFooter(DeviceFocusNodeKind kind) {
    if (kind != DeviceFocusNodeKind.security) return null;
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      key: const ValueKey('device-focus-revoke-trust'),
      onPressed: widget.onRevokeTrust,
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
    if (status['batteryPresent'] == false) return 'No battery';
    final batteryPercent = status['batteryPercent'];
    if (batteryPercent is num) return '${batteryPercent.toInt()}%';
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

  IconData _platformIcon(String? platform) {
    return switch (platform?.toLowerCase()) {
      'android' || 'ios' => Icons.smartphone,
      'windows' => Icons.desktop_windows,
      'macos' => Icons.laptop_mac,
      'linux' => Icons.computer,
      _ => Icons.devices,
    };
  }
}

class _DeviceFocusNodeData {
  const _DeviceFocusNodeData({
    required this.kind,
    required this.icon,
    required this.value,
    required this.label,
  });

  final DeviceFocusNodeKind kind;
  final IconData icon;
  final String value;
  final String label;
}
