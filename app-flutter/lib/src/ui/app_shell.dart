import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../screens/security_dashboard_screen.dart';
import '../../screens/trusted_devices_screen.dart';
import '../../screens/clipboard_transfer_screen.dart';
import '../../screens/operations_screen.dart';
import '../../screens/settings_screen.dart';
import '../../screens/local_activity_screen.dart';
import '../../screens/pair_device_screen.dart';
import '../platform/notification_route.dart';
import '../ui/local_events_notifier.dart';
import '../ui/theme.dart';

class AppShell extends StatefulWidget {
  final ValueNotifier<String?>? historyRouteNotifier;
  final ValueNotifier<String?>? sharedClipboardTextNotifier;

  const AppShell({
    super.key,
    this.historyRouteNotifier,
    this.sharedClipboardTextNotifier,
  });

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  bool _isSidebarCollapsed = false;
  double _sidebarWidth = RiftDesign.sidebarWidth;
  double _horizontalDragDistance = 0;

  late final List<Widget> _screens = [
    const TrustedDevicesScreen(),
    ClipboardTransferScreen(
      routeNotifier: widget.historyRouteNotifier,
      sharedClipboardTextNotifier: widget.sharedClipboardTextNotifier,
      onBoundarySwipe: _handleActivityBoundarySwipe,
    ),
    const OperationsScreen(),
    const SecurityDashboardScreen(),
    const SettingsScreen(),
  ];

  void showHistoryRoute(String route) {
    setState(() {
      _currentIndex = 1;
    });
    widget.historyRouteNotifier?.value = route;
  }

  void showNotificationsRoute() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.72,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(RiftDesign.radiusXl),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: LocalActivityPanel(
                onClose: () => Navigator.of(sheetContext).pop(),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleActivityBoundarySwipe(int direction) {
    _moveToMainSection(direction);
  }

  void _moveToMainSection(int direction) {
    if (_currentIndex < 0 || _currentIndex > 3) return;
    final nextIndex = (_currentIndex + direction).clamp(0, 3);
    if (nextIndex == _currentIndex) return;
    setState(() => _currentIndex = nextIndex);
  }

  void _handleMainHorizontalDragEnd(DragEndDetails details) {
    if (_currentIndex == 1) return;
    final velocity = details.primaryVelocity ?? 0;
    if (_horizontalDragDistance.abs() < 48 && velocity.abs() < 350) {
      return;
    }
    final direction = velocity.abs() >= 350
        ? (velocity < 0 ? 1 : -1)
        : (_horizontalDragDistance < 0 ? 1 : -1);
    _moveToMainSection(direction);
  }

  Widget _buildMainSwipeArea(Widget child) {
    return GestureDetector(
      key: const ValueKey('main-navigation-swipe-area'),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _horizontalDragDistance = 0,
      onHorizontalDragUpdate: (details) {
        _horizontalDragDistance += details.delta.dx;
      },
      onHorizontalDragEnd: _handleMainHorizontalDragEnd,
      child: child,
    );
  }

  void showRoute(String route) {
    if (route == NotificationRoute.devices) {
      setState(() {
        _currentIndex = 0;
      });
      return;
    }
    showHistoryRoute(route);
  }

  Widget _buildSidebarItem(
      BuildContext context, int index, IconData icon, String label) {
    final theme = Theme.of(context);
    final isSelected = _currentIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: InkWell(
        onTap: () {
          setState(() {
            _currentIndex = index;
          });
        },
        borderRadius: BorderRadius.circular(RiftDesign.radius),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: _isSidebarCollapsed ? 0 : 16, vertical: 12),
          alignment:
              _isSidebarCollapsed ? Alignment.center : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0047AB) : Colors.transparent,
            borderRadius: BorderRadius.circular(RiftDesign.radius),
          ),
          child: Row(
            mainAxisSize:
                _isSidebarCollapsed ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(
                icon,
                color: isSelected
                    ? const Color(0xFFdae2ff)
                    : const Color(0xFF8899b8),
              ),
              if (!_isSidebarCollapsed) ...[
                const SizedBox(width: 16),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: isSelected
                        ? const Color(0xFFdae2ff)
                        : const Color(0xFF8899b8),
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopTopBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          if (_isSidebarCollapsed) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset('assets/images/rift_nav_logo.png',
                  width: 44, height: 44, fit: BoxFit.contain),
            ),
            const SizedBox(width: 12),
            Text(
              'Rift',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
          const Spacer(),
          if (_isSidebarCollapsed)
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Add Device',
              onPressed: () => _showAddDeviceDialog(context),
              style: IconButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Tooltip(
              message: 'Add Device',
              child: FilledButton.icon(
                onPressed: () => _showAddDeviceDialog(context),
                icon: const Icon(Icons.add_circle_outline, size: 18),
                label: const Text('Add Device'),
                style: FilledButton.styleFrom(
                  foregroundColor: theme.colorScheme.onPrimary,
                  backgroundColor: theme.colorScheme.primary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(RiftDesign.radius),
                  ),
                ),
              ),
            ),
          SizedBox(width: _isSidebarCollapsed ? 6 : 14),
          _TopBarPopoverButton(
            icon: Icons.notifications_outlined,
            activeIcon: Icons.notifications,
            tooltip: 'Rift Activity',
            offset: const Offset(-340, 48),
            badge:
                context.select<LocalEventsNotifier, int>((n) => n.unreadCount),
            popoverBuilder: (close) =>
                _buildNotificationsPopover(context, close),
          ),
          SizedBox(width: _isSidebarCollapsed ? 6 : 14),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => _showSettingsDialog(context),
            style: IconButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _showAddDeviceDialog(BuildContext context) {
    if (MediaQuery.of(context).size.width < 1024) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const PairDeviceScreen(),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => const Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: PairDeviceScreen(),
      ),
    );
  }

  void _showSettingsDialog(BuildContext context) {
    if (MediaQuery.of(context).size.width < 1024) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => SettingsScreen(
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (dialogContext) => _ResizableDialogContainer(
        child: SettingsScreen(
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      ),
    );
  }

  Widget _buildNotificationsPopover(BuildContext context, VoidCallback close) {
    final theme = Theme.of(context);
    return Container(
      width: 380,
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LocalActivityPanel(onClose: close),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildForWidth(context, constraints.maxWidth),
    );
  }

  Widget _buildForWidth(BuildContext context, double availableWidth) {
    final theme = Theme.of(context);
    final isDesktop = availableWidth >= RiftDesign.compactBreakpoint;

    Widget content;
    if (isDesktop) {
      content = Scaffold(
        body: Row(
          children: [
            // Sidebar
            Container(
              width: _isSidebarCollapsed ? 88 : _sidebarWidth,
              color: RiftDesign.sidebar,
              padding: EdgeInsets.all(_isSidebarCollapsed ? 16 : 24),
              child: Column(
                crossAxisAlignment: _isSidebarCollapsed
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.stretch,
                children: [
                  // Header
                  InkWell(
                    onTap: () {
                      setState(() {
                        _isSidebarCollapsed = !_isSidebarCollapsed;
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisAlignment: _isSidebarCollapsed
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset('assets/images/rift_nav_logo.png',
                              width: 52, height: 52, fit: BoxFit.contain),
                        ),
                        if (!_isSidebarCollapsed) ...[
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Rift',
                                  style:
                                      theme.textTheme.headlineLarge?.copyWith(
                                    color: const Color(
                                        0xFFdae2ff), // primary-fixed
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  'Secure Sync v0.1',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: const Color(
                                        0xFFb1c5ff), // primary-fixed-dim
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Navigation
                  Expanded(
                    child: ListView(
                      children: [
                        _buildSidebarItem(context, 0, Icons.devices, 'Devices'),
                        _buildSidebarItem(
                            context, 1, Icons.history, 'Activity'),
                        _buildSidebarItem(
                            context, 2, Icons.route, 'Operations'),
                        _buildSidebarItem(
                            context, 3, Icons.security, 'Security'),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Resizable Handle for Sidebar
            if (!_isSidebarCollapsed)
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanUpdate: (details) {
                    setState(() {
                      _sidebarWidth = (_sidebarWidth + details.delta.dx)
                          .clamp(200.0, 500.0);
                    });
                  },
                  child: Container(
                    width: 8,
                    color: Colors.transparent,
                    child: Center(
                      child: Container(
                        width: 2,
                        height: 40,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Main Content
            Expanded(
              child: Column(
                children: [
                  _buildDesktopTopBar(context),
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: RiftDesign.contentMaxWidth,
                        ),
                        child: _buildMainSwipeArea(
                          IndexedStack(
                            index: _currentIndex,
                            children: _screens,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      // Mobile
      final mobileNavIndex = _currentIndex <= 3 ? _currentIndex : -1;
      content = Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // App bar
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                      bottom: BorderSide(
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.5))),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset('assets/images/rift_nav_logo.png',
                          width: 32, height: 32, fit: BoxFit.contain),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Rift',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: 'Add Device',
                      color: theme.colorScheme.onSurfaceVariant,
                      onPressed: () => _showAddDeviceDialog(context),
                    ),
                    _MobileBellButton(onTap: showNotificationsRoute),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Settings',
                      color: theme.colorScheme.onSurfaceVariant,
                      onPressed: () => _showSettingsDialog(context),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: _buildMainSwipeArea(
                  IndexedStack(
                    index: _currentIndex,
                    children: _screens,
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                return theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  fontWeight: states.contains(WidgetState.selected)
                      ? FontWeight.w600
                      : FontWeight.w500,
                );
              }),
            ),
            child: NavigationBar(
              height: 64,
              selectedIndex: mobileNavIndex == -1 ? 0 : mobileNavIndex,
              backgroundColor: Colors.transparent,
              elevation: 0,
              indicatorColor: mobileNavIndex == -1
                  ? Colors.transparent
                  : theme.colorScheme.primary.withValues(alpha: 0.08),
              onDestinationSelected: (index) {
                setState(() {
                  _currentIndex = index;
                });
              },
              destinations: [
                NavigationDestination(
                  icon: Icon(Icons.devices_outlined,
                      size: 22, color: theme.colorScheme.outline),
                  selectedIcon: Icon(Icons.devices,
                      size: 22, color: theme.colorScheme.primary),
                  label: 'Devices',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_outlined,
                      size: 22, color: theme.colorScheme.outline),
                  selectedIcon: Icon(Icons.history,
                      size: 22, color: theme.colorScheme.primary),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.route_outlined,
                      size: 22, color: theme.colorScheme.outline),
                  selectedIcon: Icon(Icons.route,
                      size: 22, color: theme.colorScheme.primary),
                  label: 'Operations',
                ),
                NavigationDestination(
                  icon: Icon(Icons.security_outlined,
                      size: 22, color: theme.colorScheme.outline),
                  selectedIcon: Icon(Icons.security,
                      size: 22, color: theme.colorScheme.primary),
                  label: 'Security',
                ),
              ],
            ),
          ),
        ),
      );
    }

    return content;
  }
}

class _ResizableDialogContainer extends StatefulWidget {
  final Widget child;

  const _ResizableDialogContainer({required this.child});

  @override
  State<_ResizableDialogContainer> createState() =>
      _ResizableDialogContainerState();
}

class _ResizableDialogContainerState extends State<_ResizableDialogContainer> {
  double? _width;
  double? _height;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final defaultWidth = (screenSize.width * 0.85).clamp(360.0, 1200.0);
    final defaultHeight = (screenSize.height * 0.8).clamp(360.0, 540.0);

    final currentWidth =
        (_width ?? defaultWidth).clamp(320.0, screenSize.width * 0.98);
    final currentHeight =
        (_height ?? defaultHeight).clamp(320.0, screenSize.height * 0.98);

    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: Center(
        child: Container(
          width: currentWidth,
          height: currentHeight,
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned.fill(child: widget.child),
                // Right resize edge
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: 8,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanUpdate: (details) {
                        setState(() {
                          _width = (currentWidth + details.delta.dx)
                              .clamp(320.0, screenSize.width * 0.98);
                        });
                      },
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                ),
                // Bottom resize edge
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 8,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeRow,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanUpdate: (details) {
                        setState(() {
                          _height = (currentHeight + details.delta.dy)
                              .clamp(320.0, screenSize.height * 0.98);
                        });
                      },
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                ),
                // Bottom-Right corner resize handle
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: 24,
                  height: 24,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeUpLeftDownRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanUpdate: (details) {
                        setState(() {
                          _width = (currentWidth + details.delta.dx)
                              .clamp(320.0, screenSize.width * 0.98);
                          _height = (currentHeight + details.delta.dy)
                              .clamp(320.0, screenSize.height * 0.98);
                        });
                      },
                      child: Container(
                        alignment: Alignment.bottomRight,
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.open_in_full,
                          size: 12,
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBarPopoverButton extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final String tooltip;
  final Offset offset;
  final Widget Function(VoidCallback close) popoverBuilder;
  final int badge;

  const _TopBarPopoverButton({
    required this.icon,
    required this.activeIcon,
    required this.tooltip,
    this.offset = const Offset(-340, 48),
    required this.popoverBuilder,
    this.badge = 0,
  });

  @override
  State<_TopBarPopoverButton> createState() => _TopBarPopoverButtonState();
}

class _TopBarPopoverButtonState extends State<_TopBarPopoverButton> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  bool get _isActive => _isOpen;

  void _togglePopover() {
    if (_isOpen) {
      _closePopover();
    } else {
      _openPopover();
    }
  }

  void _openPopover() {
    if (_overlayEntry != null) return;
    setState(() => _isOpen = true);

    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closePopover,
              child: const SizedBox.shrink(),
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: widget.offset,
            child: Material(
              color: Colors.transparent,
              child: widget.popoverBuilder(_closePopover),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _closePopover() {
    if (!_isOpen) return;
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() => _isOpen = false);
    }
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CompositedTransformTarget(
      link: _layerLink,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IconButton(
            icon: Icon(_isActive ? widget.activeIcon : widget.icon),
            tooltip: widget.tooltip,
            onPressed: _togglePopover,
            style: IconButton.styleFrom(
              foregroundColor: _isActive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
              backgroundColor: _isActive
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                  : null,
            ),
          ),
          if (widget.badge > 0)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: theme.colorScheme.error,
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: theme.colorScheme.surface, width: 1.5),
                ),
                child: Center(
                  child: Text(
                    widget.badge > 9 ? '9+' : '${widget.badge}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onError,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MobileBellButton extends StatelessWidget {
  const _MobileBellButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread =
        context.select<LocalEventsNotifier, int>((n) => n.unreadCount);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_outlined),
          tooltip: 'Rift Activity',
          color: theme.colorScheme.onSurfaceVariant,
          onPressed: onTap,
        ),
        if (unread > 0)
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                shape: BoxShape.circle,
                border:
                    Border.all(color: theme.colorScheme.surface, width: 1.5),
              ),
              child: Center(
                child: Text(
                  unread > 9 ? '9+' : '$unread',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onError,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
