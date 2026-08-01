import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import 'views/clipboard_history_view.dart';
import 'views/file_send_view.dart';
import 'views/incoming_offers_view.dart';
import 'views/transfer_activity_view.dart';

enum HistorySection {
  clipboard,
  send,
  incomingOffers,
  transferActivity,
}

class ClipboardTransferScreen extends StatefulWidget {
  final String? deviceId;
  final String? displayName;

  final ValueNotifier<String?>? routeNotifier;
  final ValueNotifier<String?>? sharedClipboardTextNotifier;

  final Future<List<Map<String, String>>> Function()? pickSendFilesOverride;
  final bool? revealCompletedTransfersInFolderOverride;
  final Future<String?> Function(String fileName)?
      buildIncomingDestinationPathOverride;
  final ValueChanged<int>? onBoundarySwipe;

  const ClipboardTransferScreen({
    super.key,
    this.deviceId,
    this.displayName,
    this.routeNotifier,
    this.sharedClipboardTextNotifier,
    this.pickSendFilesOverride,
    this.revealCompletedTransfersInFolderOverride,
    this.buildIncomingDestinationPathOverride,
    this.onBoundarySwipe,
  });

  @override
  State<ClipboardTransferScreen> createState() =>
      _ClipboardTransferScreenState();
}

class _ClipboardTransferScreenState extends State<ClipboardTransferScreen> {
  HistorySection _activeSection = HistorySection.clipboard;
  int _incomingOfferCount = 0;
  int _transferActivityCount = 0;
  final List<StreamSubscription<dynamic>> _activitySubscriptions = [];
  double _horizontalDragDistance = 0;

  String get _screenTitle {
    if (widget.displayName != null && widget.displayName!.isNotEmpty) {
      return 'Activity — ${widget.displayName}';
    }
    return 'Activity';
  }

  @override
  void initState() {
    super.initState();
    widget.routeNotifier?.addListener(_handleExternalRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleExternalRoute();
      _refreshSectionCounts();
    });
    final client = context.read<JsonRpcRiftClient>();
    _activitySubscriptions
      ..add(client.onFileOffer.listen((_) => _refreshSectionCounts()))
      ..add(
          client.onFileTransferProgress.listen((_) => _refreshSectionCounts()))
      ..add(
          client.onFileTransferCompleted.listen((_) => _refreshSectionCounts()))
      ..add(client.onFileTransferFailed.listen((_) => _refreshSectionCounts()))
      ..add(client.onConnectionChanged.listen((connected) {
        if (connected) _refreshSectionCounts();
      }));
  }

  @override
  void dispose() {
    widget.routeNotifier?.removeListener(_handleExternalRoute);
    for (final subscription in _activitySubscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  void _handleExternalRoute() {
    final route = widget.routeNotifier?.value;
    if (route == null || !mounted) {
      return;
    }

    final nextSection = switch (route) {
      'history.clipboard' => HistorySection.clipboard,
      'history.send' => HistorySection.send,
      'history.incoming_offers' => HistorySection.incomingOffers,
      'history.transfer_activity' => HistorySection.transferActivity,
      _ => null,
    };

    if (nextSection != null && _activeSection != nextSection) {
      setState(() => _activeSection = nextSection);
    }

    widget.routeNotifier?.value = null;
  }

  Future<void> _refreshSectionCounts() async {
    if (!mounted) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    try {
      final transfersResult = await client.listFileTransfers();
      final offersResult = await client.listIncomingFileOffers();
      if (!mounted) {
        return;
      }

      setState(() {
        _transferActivityCount =
            (transfersResult['transfers'] as List? ?? const <dynamic>[]).length;
        _incomingOfferCount =
            (offersResult['offers'] as List? ?? const <dynamic>[]).length;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            _buildHeader(theme),
            _buildSectionTabBar(theme),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey(
                  'history-section-content-${_activeSection.name}',
                ),
                child: _buildActiveSection(theme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_horizontalDragDistance.abs() < 48 && velocity.abs() < 350) {
      return;
    }

    final direction = velocity.abs() >= 350
        ? (velocity < 0 ? 1 : -1)
        : (_horizontalDragDistance < 0 ? 1 : -1);
    final sections = HistorySection.values;
    final currentIndex = sections.indexOf(_activeSection);
    final nextIndex = currentIndex + direction;
    if (nextIndex >= 0 && nextIndex < sections.length) {
      setState(() => _activeSection = sections[nextIndex]);
      unawaited(_refreshSectionCounts());
      return;
    }

    widget.onBoundarySwipe?.call(direction);
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _screenTitle,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTabBar(ThemeData theme) {
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
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _buildSectionChip(theme, HistorySection.clipboard, 'Clipboard'),
            const SizedBox(width: 16),
            _buildSectionChip(theme, HistorySection.send, 'Send File'),
            const SizedBox(width: 16),
            _buildSectionChip(
              theme,
              HistorySection.incomingOffers,
              'Incoming Offers',
              badgeCount: _incomingOfferCount,
            ),
            const SizedBox(width: 16),
            _buildSectionChip(
              theme,
              HistorySection.transferActivity,
              'Transfer Activity',
              badgeCount: _transferActivityCount,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionChip(
    ThemeData theme,
    HistorySection section,
    String label, {
    int? badgeCount,
  }) {
    final isSelected = _activeSection == section;
    final primaryColor = theme.colorScheme.primary;
    final onSurfaceVariant = theme.colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _activeSection = section;
          });
          unawaited(_refreshSectionCounts());
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? primaryColor : Colors.transparent,
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
                  color: isSelected ? primaryColor : onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              if (badgeCount != null && badgeCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  constraints: const BoxConstraints(minWidth: 18),
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badgeCount.toString(),
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

  Widget _buildActiveSection(ThemeData theme) {
    switch (_activeSection) {
      case HistorySection.clipboard:
        return const ClipboardHistoryView();
      case HistorySection.send:
        return FileSendView(
          pickSendFilesOverride: widget.pickSendFilesOverride,
          onViewActivityRequested: () {
            setState(() {
              _activeSection = HistorySection.transferActivity;
            });
          },
        );
      case HistorySection.incomingOffers:
        return IncomingOffersView(
          buildDestinationPathOverride:
              widget.buildIncomingDestinationPathOverride,
          onOffersChanged: _refreshSectionCounts,
        );
      case HistorySection.transferActivity:
        return TransferActivityView(
          revealCompletedTransfersInFolderOverride:
              widget.revealCompletedTransfersInFolderOverride,
        );
    }
  }
}
