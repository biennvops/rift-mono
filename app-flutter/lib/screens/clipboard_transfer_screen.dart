import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/file_transfer/send_queue_controller.dart';
import '../src/file_transfer/send_queue_panel.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/platform/ios_clipboard.dart';
import '../src/platform/notification_route.dart';
import '../src/ui/activity_navigation.dart';
import '../src/ui/motion.dart';
import '../src/ui/theme.dart';
import 'views/clipboard_history_view.dart';
import 'views/file_send_view.dart';
import 'views/incoming_offers_view.dart';
import 'views/transfer_activity_view.dart';
import 'local_activity_screen.dart';

enum _HistorySection {
  clipboard,
  notifications,
  send,
  incomingOffers,
  transferActivity,
}

const _activitySectionOrder = <_HistorySection>[
  _HistorySection.clipboard,
  _HistorySection.send,
  _HistorySection.incomingOffers,
  _HistorySection.transferActivity,
  _HistorySection.notifications,
];

class ClipboardTransferScreen extends StatefulWidget {
  final String? deviceId;
  final String? displayName;
  final Future<List<Map<String, String>>> Function()? pickSendFilesOverride;
  final bool? revealCompletedTransfersInFolderOverride;
  final bool? exportCompletedTransfersOverride;
  final Future<void> Function(String path)? openFileOverride;
  final Future<void> Function(String path)? exportFileOverride;
  final bool? iosClipboardActionsOverride;
  final Future<IOSClipboardContent?> Function()? readClipboardContentOverride;
  final Future<String?> Function()? readClipboardTextOverride;
  final Future<void> Function(IOSClipboardContent content)?
      writeClipboardContentOverride;
  final Future<void> Function(String text)? writeClipboardTextOverride;
  final Future<String?> Function(String fileName)?
      buildIncomingDestinationPathOverride;
  final ValueNotifier<String?>? routeNotifier;
  final ValueNotifier<ActivityNavigationRequest?>? activityNavigationNotifier;
  final ValueNotifier<String?>? sharedClipboardTextNotifier;
  final ValueChanged<int>? onBoundarySwipe;

  const ClipboardTransferScreen({
    super.key,
    this.deviceId,
    this.displayName,
    this.pickSendFilesOverride,
    this.revealCompletedTransfersInFolderOverride,
    this.exportCompletedTransfersOverride,
    this.openFileOverride,
    this.exportFileOverride,
    this.iosClipboardActionsOverride,
    this.readClipboardContentOverride,
    this.readClipboardTextOverride,
    this.writeClipboardContentOverride,
    this.writeClipboardTextOverride,
    this.buildIncomingDestinationPathOverride,
    this.routeNotifier,
    this.activityNavigationNotifier,
    this.sharedClipboardTextNotifier,
    this.onBoundarySwipe,
  });

  @override
  State<ClipboardTransferScreen> createState() =>
      _ClipboardTransferScreenState();
}

class _ClipboardTransferScreenState extends State<ClipboardTransferScreen> {
  _HistorySection _activeSection = _HistorySection.clipboard;
  int _activityTransitionDirection = 1;
  double _horizontalDragDistance = 0;
  int _activeOutgoingTransferCount = 0;
  String? _targetDeviceId;
  String? _targetDisplayName;
  int _targetRequestVersion = 0;
  StreamSubscription? _progressSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _failedSub;

  @override
  void initState() {
    super.initState();
    widget.routeNotifier?.addListener(_handleExternalRoute);
    widget.activityNavigationNotifier?.addListener(_handleActivityNavigation);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleExternalRoute();
      _handleActivityNavigation();
      _loadActiveTransfers();
      _bindTransferEvents();
    });
  }

  @override
  void dispose() {
    widget.routeNotifier?.removeListener(_handleExternalRoute);
    widget.activityNavigationNotifier
        ?.removeListener(_handleActivityNavigation);
    _progressSub?.cancel();
    _completedSub?.cancel();
    _failedSub?.cancel();
    super.dispose();
  }

  void _bindTransferEvents() {
    final client = context.read<JsonRpcRiftClient>();
    _progressSub = client.onFileProgress.listen((_) => _loadActiveTransfers());
    _completedSub =
        client.onFileCompleted.listen((_) => _loadActiveTransfers());
    _failedSub = client.onFileFailed.listen((_) => _loadActiveTransfers());
  }

  Future<void> _loadActiveTransfers() async {
    try {
      final client = context.read<JsonRpcRiftClient>();
      final result = await client.listFileTransfers();
      final transfers = List<Map<String, dynamic>>.from(
        (result['transfers'] as List? ?? const <dynamic>[])
            .map((item) => Map<String, dynamic>.from(item as Map)),
      );
      final count = transfers.where((t) {
        final dir = t['direction']?.toString();
        final isIncoming = t['isIncoming'] == true || dir == 'incoming';
        final state = t['state']?.toString().toLowerCase() ?? '';
        final status = t['status']?.toString().toLowerCase() ?? '';
        final isActive = state == 'active' ||
            state == 'pending' ||
            state == 'in_progress' ||
            status == 'sending' ||
            status == 'in_progress';
        return !isIncoming && isActive;
      }).length;
      if (mounted) {
        setState(() => _activeOutgoingTransferCount = count);
      }
    } catch (_) {}
  }

  void _handleExternalRoute() {
    final route = widget.routeNotifier?.value;
    if (route == null || !mounted) return;

    final nextSection = _sectionForRoute(route);
    if (nextSection != null) {
      _selectActivitySection(nextSection);
    }
    widget.routeNotifier?.value = null;
  }

  void _handleActivityNavigation() {
    final request = widget.activityNavigationNotifier?.value;
    if (request == null || !mounted) return;

    final nextSection = _sectionForRoute(request.route);
    if (nextSection == null) return;

    _selectActivitySection(nextSection);
    setState(() {
      _targetDeviceId = request.deviceId;
      _targetDisplayName = request.displayName;
      _targetRequestVersion++;
    });
    widget.activityNavigationNotifier?.value = null;
  }

  _HistorySection? _sectionForRoute(String route) {
    return switch (route) {
      NotificationRoute.historyClipboard => _HistorySection.clipboard,
      NotificationRoute.historyNotifications => _HistorySection.notifications,
      NotificationRoute.historySend => _HistorySection.send,
      NotificationRoute.historyIncomingOffers => _HistorySection.incomingOffers,
      NotificationRoute.historyTransferActivity =>
        _HistorySection.transferActivity,
      _ => null,
    };
  }

  void _selectActivitySection(_HistorySection section) {
    if (section == _activeSection) return;

    final currentIndex = _activitySectionOrder.indexOf(_activeSection);
    final nextIndex = _activitySectionOrder.indexOf(section);
    if (currentIndex < 0 || nextIndex < 0) return;

    setState(() {
      _activityTransitionDirection = nextIndex > currentIndex ? 1 : -1;
      _activeSection = section;
    });
  }

  void _clearTargetDevice() {
    setState(() {
      _targetDeviceId = null;
      _targetDisplayName = null;
      _targetRequestVersion++;
    });
  }

  void _clearTargetScopeFromFilter() {
    setState(() {
      _targetDeviceId = null;
      _targetDisplayName = null;
    });
  }

  bool get _targetScopeVisible {
    final targetDeviceId = _targetDeviceId;
    if (targetDeviceId == null || targetDeviceId.isEmpty) return false;
    return switch (_activeSection) {
      _HistorySection.clipboard ||
      _HistorySection.send ||
      _HistorySection.transferActivity =>
        true,
      _HistorySection.incomingOffers || _HistorySection.notifications => false,
    };
  }

  String get _activityTitle {
    final target = _targetDisplayName;
    if (_targetScopeVisible && target != null && target.isNotEmpty) {
      return 'Activity — $target';
    }
    if (!_targetScopeVisible && _targetDeviceId?.isNotEmpty == true) {
      return 'Activity';
    }
    final legacyDisplayName = widget.displayName;
    return legacyDisplayName == null || legacyDisplayName.isEmpty
        ? 'Activity'
        : 'Activity — $legacyDisplayName';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _buildRiftActivityUi(theme);
  }

  Widget _buildRiftActivityUi(ThemeData theme) {
    final title = _activityTitle;

    final isDesktop =
        MediaQuery.of(context).size.width >= RiftDesign.compactBreakpoint;
    final screenPadding =
        isDesktop ? RiftDesign.padScreenDesktop : RiftDesign.padScreenMobile;

    return GestureDetector(
      key: const ValueKey('activity-section-swipe-area'),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _horizontalDragDistance = 0,
      onHorizontalDragUpdate: (details) {
        _horizontalDragDistance += details.delta.dx;
      },
      onHorizontalDragEnd: _handleHorizontalDragEnd,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                screenPadding.left,
                screenPadding.top,
                screenPadding.right,
                RiftDesign.spaceMd,
              ),
              child: Text(
                title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            _buildRiftSectionTabBar(theme),
            AnimatedSize(
              duration: RiftMotion.durationOf(context, RiftMotion.normal),
              curve: RiftMotion.move,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: RiftMotion.durationOf(context, RiftMotion.fast),
                switchInCurve: RiftMotion.enter,
                switchOutCurve: RiftMotion.exit,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                ),
                child: _targetScopeVisible
                    ? _buildTargetScopeChip(theme)
                    : const SizedBox(
                        key: ValueKey('activity-target-chip-empty'),
                        height: 0,
                      ),
              ),
            ),
            Expanded(
              child: _buildActivitySectionTransition(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivitySectionTransition() {
    final activeKey = ValueKey<String>(
      'history-section-content-${_activeSection.name}',
    );
    final travel = Offset(0.035 * _activityTransitionDirection, 0);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: RiftMotion.durationOf(context, RiftMotion.normal),
        switchInCurve: RiftMotion.enter,
        switchOutCurve: RiftMotion.exit,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            fit: StackFit.expand,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) {
          final isActive = child.key == activeKey;
          final begin = isActive ? travel : Offset.zero;
          final end = isActive ? Offset.zero : -travel;
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: begin,
                end: end,
              ).animate(animation),
              child: IgnorePointer(
                ignoring: !isActive,
                child: ExcludeSemantics(
                  excluding: !isActive,
                  child: child,
                ),
              ),
            ),
          );
        },
        child: KeyedSubtree(
          key: activeKey,
          child: _buildRiftActiveSection(),
        ),
      ),
    );
  }

  Widget _buildTargetScopeChip(ThemeData theme) {
    final label = _targetDisplayName == null || _targetDisplayName!.isEmpty
        ? _shortDeviceId(_targetDeviceId!)
        : _targetDisplayName!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(
          key: const ValueKey('activity-target-chip'),
          avatar: const Icon(Icons.devices, size: 16),
          label: Text(label),
          onDeleted: _clearTargetDevice,
          deleteButtonTooltipMessage: 'Clear device scope',
        ),
      ),
    );
  }

  String _shortDeviceId(String deviceId) {
    return deviceId.length > 16 ? '${deviceId.substring(0, 16)}…' : deviceId;
  }

  Widget _buildRiftSectionTabBar(ThemeData theme) {
    final isDesktop =
        MediaQuery.of(context).size.width >= RiftDesign.compactBreakpoint;
    final horizontalPad = isDesktop ? RiftDesign.spaceLg : RiftDesign.spaceMd;
    final sendQueue = context.watch<SendQueueController?>();
    final activeQueueCount = sendQueue?.items
            .where((e) =>
                e.status == SendQueueStatus.sending ||
                e.status == SendQueueStatus.queued)
            .length ??
        0;
    final totalBadgeCount =
        activeQueueCount > 0 ? activeQueueCount : _activeOutgoingTransferCount;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: horizontalPad),
        child: Row(
          children: [
            for (var index = 0;
                index < _activitySectionOrder.length;
                index++) ...[
              if (index > 0) const SizedBox(width: 16),
              _buildRiftSectionChip(
                theme,
                _activitySectionOrder[index],
                _activitySectionLabel(_activitySectionOrder[index]),
                badgeCount: _activitySectionOrder[index] ==
                        _HistorySection.transferActivity
                    ? totalBadgeCount
                    : 0,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _activitySectionLabel(_HistorySection section) {
    return switch (section) {
      _HistorySection.clipboard => 'Clipboard',
      _HistorySection.send => 'Send File',
      _HistorySection.incomingOffers => 'Incoming Offers',
      _HistorySection.transferActivity => 'Transfer Activity',
      _HistorySection.notifications => 'Notifications',
    };
  }

  Widget _buildRiftSectionChip(
    ThemeData theme,
    _HistorySection section,
    String label, {
    int badgeCount = 0,
  }) {
    final isSelected = _activeSection == section;

    return Material(
      color: Colors.transparent,
      child: Semantics(
        button: true,
        selected: isSelected,
        label: label,
        child: InkWell(
          key: ValueKey('activity-tab-${section.name}'),
          onTap: () => _selectActivitySection(section),
          child: AnimatedContainer(
            duration: RiftMotion.durationOf(context, RiftMotion.fast),
            curve: RiftMotion.move,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedDefaultTextStyle(
                  duration: RiftMotion.durationOf(context, RiftMotion.fast),
                  curve: RiftMotion.move,
                  style: TextStyle(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  child: Text(label),
                ),
                if (badgeCount > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    constraints: const BoxConstraints(minWidth: 18),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '$badgeCount',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.onPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRiftActiveSection() {
    switch (_activeSection) {
      case _HistorySection.clipboard:
        return ClipboardHistoryView(
          key: ValueKey('clipboard-history-$_targetRequestVersion'),
          preferredSourceDeviceId: _targetDeviceId,
          targetRequestVersion: _targetRequestVersion,
          onTargetScopeCleared: _clearTargetScopeFromFilter,
          iosClipboardActionsOverride: widget.iosClipboardActionsOverride,
          readClipboardContentOverride: widget.readClipboardContentOverride,
          readClipboardTextOverride: widget.readClipboardTextOverride,
          writeClipboardContentOverride: widget.writeClipboardContentOverride,
          writeClipboardTextOverride: widget.writeClipboardTextOverride,
        );
      case _HistorySection.send:
        return FileSendView(
          preferredTargetDeviceId: _targetDeviceId,
          targetRequestVersion: _targetRequestVersion,
          onTargetScopeCleared: _clearTargetScopeFromFilter,
          pickSendFilesOverride: widget.pickSendFilesOverride,
          onViewActivityRequested: () {
            _selectActivitySection(_HistorySection.transferActivity);
          },
        );
      case _HistorySection.incomingOffers:
        return IncomingOffersView(
          buildDestinationPathOverride:
              widget.buildIncomingDestinationPathOverride,
        );
      case _HistorySection.transferActivity:
        return TransferActivityView(
          preferredDeviceId: _targetDeviceId,
          targetRequestVersion: _targetRequestVersion,
          revealCompletedTransfersInFolderOverride:
              widget.revealCompletedTransfersInFolderOverride,
          exportCompletedTransfersOverride:
              widget.exportCompletedTransfersOverride,
          openFileOverride: widget.openFileOverride,
          exportFileOverride: widget.exportFileOverride,
          onTargetScopeCleared: _clearTargetScopeFromFilter,
        );
      case _HistorySection.notifications:
        return const LocalActivityPanel();
    }
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_horizontalDragDistance.abs() < 48 && velocity.abs() < 350) return;

    final direction = velocity.abs() >= 350
        ? (velocity < 0 ? 1 : -1)
        : (_horizontalDragDistance < 0 ? 1 : -1);
    final nextIndex = _activitySectionOrder.indexOf(_activeSection) + direction;
    if (nextIndex >= 0 && nextIndex < _activitySectionOrder.length) {
      _selectActivitySection(_activitySectionOrder[nextIndex]);
      return;
    }
    widget.onBoundarySwipe?.call(direction);
  }
}
