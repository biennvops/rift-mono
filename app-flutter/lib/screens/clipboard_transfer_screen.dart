import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/file_transfer/send_queue_controller.dart';
import '../src/file_transfer/send_queue_panel.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/platform/ios_clipboard.dart';
import '../src/platform/notification_route.dart';
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
    this.sharedClipboardTextNotifier,
    this.onBoundarySwipe,
  });

  @override
  State<ClipboardTransferScreen> createState() =>
      _ClipboardTransferScreenState();
}

class _ClipboardTransferScreenState extends State<ClipboardTransferScreen> {
  _HistorySection _activeSection = _HistorySection.clipboard;
  double _horizontalDragDistance = 0;
  int _activeOutgoingTransferCount = 0;
  StreamSubscription? _progressSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _failedSub;

  @override
  void initState() {
    super.initState();
    widget.routeNotifier?.addListener(_handleExternalRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleExternalRoute();
      _loadActiveTransfers();
      _bindTransferEvents();
    });
  }

  @override
  void dispose() {
    widget.routeNotifier?.removeListener(_handleExternalRoute);
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

    final nextSection = switch (route) {
      NotificationRoute.historyClipboard => _HistorySection.clipboard,
      NotificationRoute.historyNotifications => _HistorySection.notifications,
      NotificationRoute.historySend => _HistorySection.send,
      NotificationRoute.historyIncomingOffers => _HistorySection.incomingOffers,
      NotificationRoute.historyTransferActivity =>
        _HistorySection.transferActivity,
      _ => null,
    };
    if (nextSection != null) {
      setState(() => _activeSection = nextSection);
    }
    widget.routeNotifier?.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _buildRiftActivityUi(theme);
  }

  Widget _buildRiftActivityUi(ThemeData theme) {
    final title = widget.displayName != null && widget.displayName!.isNotEmpty
        ? 'Activity — ${widget.displayName}'
        : 'Activity';

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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
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
            Expanded(
              child: KeyedSubtree(
                key: ValueKey(
                  'history-section-content-${_activeSection.name}',
                ),
                child: _buildRiftActiveSection(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRiftSectionTabBar(ThemeData theme) {
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
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _buildRiftSectionChip(
              theme,
              _HistorySection.clipboard,
              'Clipboard',
            ),
            const SizedBox(width: 16),
            _buildRiftSectionChip(theme, _HistorySection.send, 'Send File'),
            const SizedBox(width: 16),
            _buildRiftSectionChip(
              theme,
              _HistorySection.incomingOffers,
              'Incoming Offers',
            ),
            const SizedBox(width: 16),
            _buildRiftSectionChip(
              theme,
              _HistorySection.transferActivity,
              'Transfer Activity',
              badgeCount: totalBadgeCount,
            ),
            const SizedBox(width: 16),
            _buildRiftSectionChip(
              theme,
              _HistorySection.notifications,
              'Notifications',
            ),
          ],
        ),
      ),
    );
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
      child: InkWell(
        onTap: () => setState(() => _activeSection = section),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color:
                    isSelected ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
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
    );
  }

  Widget _buildRiftActiveSection() {
    switch (_activeSection) {
      case _HistorySection.clipboard:
        return ClipboardHistoryView(
          iosClipboardActionsOverride: widget.iosClipboardActionsOverride,
          readClipboardContentOverride: widget.readClipboardContentOverride,
          readClipboardTextOverride: widget.readClipboardTextOverride,
          writeClipboardContentOverride: widget.writeClipboardContentOverride,
          writeClipboardTextOverride: widget.writeClipboardTextOverride,
        );
      case _HistorySection.send:
        return FileSendView(
          pickSendFilesOverride: widget.pickSendFilesOverride,
          onViewActivityRequested: () {
            setState(() => _activeSection = _HistorySection.transferActivity);
          },
        );
      case _HistorySection.incomingOffers:
        return IncomingOffersView(
          buildDestinationPathOverride:
              widget.buildIncomingDestinationPathOverride,
        );
      case _HistorySection.transferActivity:
        return TransferActivityView(
          revealCompletedTransfersInFolderOverride:
              widget.revealCompletedTransfersInFolderOverride,
          exportCompletedTransfersOverride:
              widget.exportCompletedTransfersOverride,
          openFileOverride: widget.openFileOverride,
          exportFileOverride: widget.exportFileOverride,
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
    final sections = _HistorySection.values;
    final nextIndex = sections.indexOf(_activeSection) + direction;
    if (nextIndex >= 0 && nextIndex < sections.length) {
      setState(() => _activeSection = sections[nextIndex]);
      return;
    }
    widget.onBoundarySwipe?.call(direction);
  }
}
