import 'package:flutter/material.dart';

import '../../screens/security_dashboard_screen.dart';
import '../../screens/trusted_devices_screen.dart';
import '../../screens/clipboard_transfer_screen.dart';
import '../../screens/operations_screen.dart';
import '../../screens/settings_screen.dart';
import '../platform/notification_route.dart';
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

  @override
  void initState() {
    super.initState();
    if (widget.historyRouteNotifier?.value != null) {
      _currentIndex = 1;
    }
  }

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

  List<Widget> _buildScreenStack() {
    return List<Widget>.generate(
      _screens.length,
      (index) => TickerMode(
        enabled: index == _currentIndex,
        child: _screens[index],
      ),
    );
  }

  void showHistoryRoute(String route) {
    setState(() {
      _currentIndex = 1;
    });
    widget.historyRouteNotifier?.value = route;
  }

  void showNotificationsRoute() {
    showHistoryRoute(NotificationRoute.historyNotifications);
  }

  void _handleActivityBoundarySwipe(int direction) {
    _moveToMainSection(direction);
  }

  void _moveToMainSection(int direction) {
    if (_currentIndex < 0 || _currentIndex > 4) return;
    final nextIndex = (_currentIndex + direction).clamp(0, 4);
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
                        _buildSidebarItem(
                            context, 4, Icons.settings, 'Settings'),
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
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: RiftDesign.contentMaxWidth,
                  ),
                  child: _buildMainSwipeArea(
                    IndexedStack(
                      index: _currentIndex,
                      children: _buildScreenStack(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // Mobile
      final mobileNavIndex = _currentIndex <= 4 ? _currentIndex : 0;
      content = Scaffold(
        body: SafeArea(
          child: _buildMainSwipeArea(
            IndexedStack(
              index: _currentIndex,
              children: _buildScreenStack(),
            ),
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
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined,
                      size: 22, color: theme.colorScheme.outline),
                  selectedIcon: Icon(Icons.settings,
                      size: 22, color: theme.colorScheme.primary),
                  label: 'Settings',
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
