import 'package:flutter/material.dart';

import '../../screens/security_dashboard_screen.dart';
import '../../screens/trusted_devices_screen.dart';
import '../../screens/clipboard_transfer_screen.dart';
import '../../screens/operations_screen.dart';
import '../../screens/settings_screen.dart';
import '../platform/notification_route.dart';
import 'activity_navigation.dart';
import '../ui/indexed_transition_stack.dart';
import '../ui/motion.dart';
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
  final ValueNotifier<ActivityNavigationRequest?> _activityNavigation =
      ValueNotifier<ActivityNavigationRequest?>(null);
  int _currentIndex = 0;
  int _mainSectionDirection = 1;
  bool _isSidebarCollapsed = false;
  bool _isResizingSidebar = false;
  double _sidebarWidth = RiftDesign.sidebarWidth;
  double _expandedSidebarWidth = RiftDesign.sidebarWidth;
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
      activityNavigationNotifier: _activityNavigation,
      sharedClipboardTextNotifier: widget.sharedClipboardTextNotifier,
      onBoundarySwipe: _handleActivityBoundarySwipe,
    ),
    const OperationsScreen(),
    const SecurityDashboardScreen(),
    const SettingsScreen(),
  ];

  void showHistoryRoute(String route) {
    _selectMainSection(1);
    _activityNavigation.value = ActivityNavigationRequest(route: route);
    widget.historyRouteNotifier?.value = route;
  }

  void showNotificationsRoute() {
    showHistoryRoute(NotificationRoute.historyNotifications);
  }

  void showActivityForDevice({
    required String route,
    required String deviceId,
    required String displayName,
  }) {
    _selectMainSection(1);
    _activityNavigation.value = ActivityNavigationRequest(
      route: route,
      deviceId: deviceId,
      displayName: displayName,
    );
  }

  void _handleActivityBoundarySwipe(int direction) {
    _moveToMainSection(direction);
  }

  void _moveToMainSection(int direction) {
    if (direction == 0) return;
    _selectMainSection(_currentIndex + (direction < 0 ? -1 : 1));
  }

  void _selectMainSection(int nextIndex, {int? direction}) {
    if (nextIndex < 0 || nextIndex >= _screens.length) return;
    if (nextIndex == _currentIndex) return;

    final nextDirection = direction == null || direction == 0
        ? (nextIndex > _currentIndex ? 1 : -1)
        : (direction < 0 ? -1 : 1);
    setState(() {
      _mainSectionDirection = nextDirection;
      _currentIndex = nextIndex;
    });
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
      _selectMainSection(0);
      return;
    }
    showHistoryRoute(route);
  }

  void _toggleSidebarCollapsed() {
    setState(() {
      if (_isSidebarCollapsed) {
        _isSidebarCollapsed = false;
        _sidebarWidth = _expandedSidebarWidth;
      } else {
        _expandedSidebarWidth = _sidebarWidth;
        _isSidebarCollapsed = true;
      }
    });
  }

  void _startSidebarResize() {
    setState(() => _isResizingSidebar = true);
  }

  void _updateSidebarResize(DragUpdateDetails details) {
    final width =
        (_sidebarWidth + details.delta.dx).clamp(200.0, 500.0).toDouble();
    setState(() {
      _sidebarWidth = width;
      _expandedSidebarWidth = width;
    });
  }

  void _finishSidebarResize() {
    if (!mounted || !_isResizingSidebar) return;
    setState(() => _isResizingSidebar = false);
  }

  Widget _buildSidebarItem(
      BuildContext context, int index, IconData icon, String label) {
    final theme = Theme.of(context);
    final isSelected = _currentIndex == index;
    final motionDuration = _isResizingSidebar
        ? Duration.zero
        : RiftMotion.durationOf(context, RiftMotion.fast);
    final labelStyle =
        (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
      color: isSelected ? const Color(0xFFdae2ff) : const Color(0xFF8899b8),
      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: InkWell(
        key: ValueKey('sidebar-item-$index'),
        onTap: () => _selectMainSection(index),
        borderRadius: BorderRadius.circular(RiftDesign.radius),
        child: AnimatedContainer(
          key: ValueKey('sidebar-item-container-$index'),
          duration: motionDuration,
          curve: RiftMotion.move,
          padding: EdgeInsets.symmetric(
            horizontal: _isSidebarCollapsed ? 0 : 16,
            vertical: 12,
          ),
          alignment:
              _isSidebarCollapsed ? Alignment.center : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0047AB) : Colors.transparent,
            borderRadius: BorderRadius.circular(RiftDesign.radius),
          ),
          child: SizedBox(
            height: 24,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedAlign(
                  duration: motionDuration,
                  curve: RiftMotion.move,
                  alignment: _isSidebarCollapsed
                      ? Alignment.center
                      : Alignment.centerLeft,
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      end: isSelected
                          ? const Color(0xFFdae2ff)
                          : const Color(0xFF8899b8),
                    ),
                    duration: motionDuration,
                    curve: RiftMotion.move,
                    builder: (context, color, child) => Icon(
                      icon,
                      color: color,
                    ),
                  ),
                ),
                Positioned(
                  left: 40,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: ClipRect(
                    child: ExcludeSemantics(
                      excluding: _isSidebarCollapsed,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: motionDuration,
                          opacity: _isSidebarCollapsed ? 0 : 1,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: AnimatedDefaultTextStyle(
                              duration: motionDuration,
                              curve: RiftMotion.move,
                              style: labelStyle,
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
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
            AnimatedContainer(
              key: const ValueKey('sidebar-container'),
              duration: _isResizingSidebar
                  ? Duration.zero
                  : RiftMotion.durationOf(context, RiftMotion.normal),
              curve: RiftMotion.move,
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
                    key: const ValueKey('sidebar-collapse-toggle'),
                    onTap: _toggleSidebarCollapsed,
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      height: 64,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AnimatedAlign(
                            duration: RiftMotion.durationOf(
                              context,
                              RiftMotion.normal,
                            ),
                            curve: RiftMotion.move,
                            alignment: _isSidebarCollapsed
                                ? Alignment.center
                                : Alignment.centerLeft,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/images/rift_nav_logo.png',
                                width: 52,
                                height: 52,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 68,
                            right: 0,
                            top: 0,
                            bottom: 0,
                            child: ClipRect(
                              child: AnimatedOpacity(
                                duration: RiftMotion.durationOf(
                                  context,
                                  RiftMotion.normal,
                                ),
                                opacity: _isSidebarCollapsed ? 0 : 1,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Rift',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.headlineLarge
                                            ?.copyWith(
                                          color: const Color(0xFFdae2ff),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        'Secure Sync v0.1',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: const Color(0xFFb1c5ff),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
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
                  key: const ValueKey('sidebar-resize-handle'),
                  onPanStart: (_) => _startSidebarResize(),
                  onPanUpdate: _updateSidebarResize,
                  onPanEnd: (_) => _finishSidebarResize(),
                  onPanCancel: _finishSidebarResize,
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
                    RiftIndexedTransitionStack(
                      key: const ValueKey('main-section-transition-stack'),
                      index: _currentIndex,
                      direction: _mainSectionDirection,
                      children: _screens,
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
            RiftIndexedTransitionStack(
              key: const ValueKey('main-section-transition-stack'),
              index: _currentIndex,
              direction: _mainSectionDirection,
              children: _screens,
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
              onDestinationSelected: _selectMainSection,
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

  @override
  void dispose() {
    _activityNavigation.dispose();
    super.dispose();
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
