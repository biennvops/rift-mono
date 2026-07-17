import 'package:flutter/material.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:provider/provider.dart';
import 'background_sync_screen.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/platform/android_shell.dart';
import '../src/platform/macos_notifications.dart';
import '../widgets/rift_snackbar.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isProcessing = false;
  bool _localNetworkPermissionPrechecked = false;
  bool _localNetworkPermissionGranted = false;
  bool _notificationPermissionPrechecked = false;
  bool _notificationPermissionGranted = false;
  bool _notificationAccessPrechecked = false;
  bool _notificationAccessGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _preloadPermissionState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshNotificationState();
    }
  }

  Future<void> _preloadPermissionState() async {
    final localNetworkGranted = await _precheckLocalNetworkPermission();
    final notificationStatus = await _loadNotificationPermissionStatus();
    final notificationAccessStatus = await _loadNotificationAccessStatus();
    if (!mounted) return;
    setState(() {
      _localNetworkPermissionPrechecked = true;
      _localNetworkPermissionGranted = localNetworkGranted;
      _notificationPermissionPrechecked = true;
      _notificationPermissionGranted = notificationStatus == 'authorized';
      _notificationAccessPrechecked = true;
      _notificationAccessGranted = notificationAccessStatus == 'authorized';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _autoAdvanceFromPrechecks();
      }
    });
  }

  Future<bool> _precheckLocalNetworkPermission() async {
    try {
      final client = context.read<JsonRpcRiftClient>();
      await client.startDiscovery();
      return true;
    } on json_rpc.RpcException catch (e) {
      final data = e.data;
      if (e.code == -32010 &&
          data is Map &&
          (data['policy']?.toString() == 'local_network')) {
        return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<String> _loadNotificationPermissionStatus() async {
    return AndroidShell.isSupported
        ? AndroidShell.getNotificationPermissionStatus()
        : MacOSNotifications.getStatus();
  }

  Future<String> _loadNotificationAccessStatus() async {
    if (AndroidShell.isSupported) {
      return AndroidShell.getNotificationListenerAccessStatus();
    }
    return 'authorized';
  }

  Future<void> _refreshNotificationState() async {
    final notificationStatus = await _loadNotificationPermissionStatus();
    final notificationAccessStatus = await _loadNotificationAccessStatus();
    if (!mounted) {
      return;
    }
    setState(() {
      _notificationPermissionPrechecked = true;
      _notificationPermissionGranted = notificationStatus == 'authorized';
      _notificationAccessPrechecked = true;
      _notificationAccessGranted = notificationAccessStatus == 'authorized';
    });
    _autoAdvanceFromPrechecks();
  }

  void _autoAdvanceFromPrechecks() {
    if (_currentPage == 0 &&
        _localNetworkPermissionPrechecked &&
        _localNetworkPermissionGranted) {
      _nextPage();
      return;
    }
    if (_currentPage == 1 &&
        _notificationPermissionPrechecked &&
        _notificationPermissionGranted &&
        _notificationAccessPrechecked &&
        _notificationAccessGranted) {
      _nextPage();
    }
  }

  Future<void> _startDiscoveryThenNext() async {
    try {
      final client = context.read<JsonRpcRiftClient>();
      await client.startDiscovery();
      if (!mounted) return;
      setState(() {
        _localNetworkPermissionGranted = true;
      });
      _nextPage();
    } on json_rpc.RpcException catch (e) {
      if (!mounted) return;
      final data = e.data;
      if (e.code == -32010 &&
          data is Map &&
          (data['policy']?.toString() == 'local_network')) {
        RiftSnackbar.show(
          context: context,
          message: 'Local network access is denied. Enable it for Rift Daemon in System Settings > Privacy & Security > Local Network.',
          type: RiftSnackbarType.error,
        );
        return;
      }
      RiftSnackbar.show(
        context: context,
        message: 'Failed to start discovery: ${e.message}',
        type: RiftSnackbarType.error,
      );
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'Failed to start discovery: $e',
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _requestNotificationsThenNext() async {
    if (_notificationPermissionGranted && _notificationAccessGranted) {
      _nextPage();
      return;
    }
    var granted = _notificationPermissionGranted;
    if (!granted) {
      granted = AndroidShell.isSupported
          ? await AndroidShell.requestNotificationPermission()
          : await MacOSNotifications.request();
    }
    if (!mounted) return;
    if (granted) {
      setState(() {
        _notificationPermissionGranted = true;
      });
    }
    if (!granted) {
      RiftSnackbar.show(
        context: context,
        message: 'Notifications are disabled. You can enable them later in System Settings > Notifications.',
        type: RiftSnackbarType.warning,
      );
      _nextPage();
      return;
    }

    if (AndroidShell.isSupported && !_notificationAccessGranted) {
      final opened = await AndroidShell.openNotificationListenerSettings();
      if (!mounted) return;
      if (!opened) {
        RiftSnackbar.show(
          context: context,
          message: 'Unable to open Android notification access settings. You can enable it later in Settings.',
          type: RiftSnackbarType.warning,
        );
        _nextPage();
        return;
      }
      RiftSnackbar.show(
        context: context,
        message: 'Enable Rift notification access in the Android settings screen, then return to continue.',
        type: RiftSnackbarType.info,
      );
      return;
    }
    _nextPage();
  }

  void _nextPage() {
    if (_currentPage < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _finishOnboarding() async {
    setState(() {
      _isProcessing = true;
    });

    // Mock processing delay
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    // Navigate to Background Sync detailed permission screen
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const BackgroundSyncScreen()),
    );
  }

  Widget _buildDot(int index, ThemeData theme) {
    final isActive = _currentPage == index;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: isActive
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant,
        shape: BoxShape.circle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield,
                          color: theme.colorScheme.primary, size: 28),
                      const SizedBox(width: 8),
                      Text(
                        'RIFT',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      _buildDot(0, theme),
                      _buildDot(1, theme),
                      _buildDot(2, theme),
                    ],
                  ),
                ],
              ),
            ),
            // Main Canvas
            Expanded(
              child: PageView(
                controller: _pageController,
                physics:
                    const NeverScrollableScrollPhysics(), // Disable swipe to force button clicks
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _currentPage == index) {
                      _autoAdvanceFromPrechecks();
                    }
                  });
                },
                children: [
                  // Card 1: Local Network
                  _buildOnboardingCard(
                    theme: theme,
                    icon: Icons.wifi_tethering,
                    iconBgColor: theme.colorScheme.primaryContainer
                        .withValues(alpha: 0.2),
                    iconColor: theme.colorScheme.primary,
                    title: 'Local Network',
                    description:
                        'Rift requires local network access to securely discover and synchronize with nearby trusted devices over encrypted channels.',
                    infoTag: 'MANDATORY FOR CORE FUNCTIONALITY',
                    actions: [
                      _buildPrimaryButton(
                        'Grant Permission',
                        theme,
                        _startDiscoveryThenNext,
                      ),
                    ],
                  ),
                  // Card 2: Notifications
                  _buildOnboardingCard(
                    theme: theme,
                    icon: Icons.notifications,
                    iconBgColor: theme.colorScheme.secondaryContainer
                        .withValues(alpha: 0.3),
                    iconColor: theme.colorScheme.secondary,
                    title: 'Alerts & Logs',
                    description: AndroidShell.isSupported
                        ? 'Enable Android notifications and notification access so Rift can show alerts and mirror Android notifications to your trusted desktop devices.'
                        : 'Enable push notifications to receive real-time alerts on unauthorized access attempts and device sync status.',
                    actions: [
                      _buildPrimaryButton(
                          AndroidShell.isSupported
                              ? 'Enable Alerts & Sync'
                              : 'Enable Alerts',
                          theme,
                          _requestNotificationsThenNext),
                      const SizedBox(height: 8),
                      _buildOutlinedButton('Skip for Now', theme, _nextPage),
                    ],
                  ),
                  // Card 3: Battery Optimization
                  _buildOnboardingCard(
                    theme: theme,
                    icon: Icons.battery_saver,
                    iconBgColor: theme.colorScheme.tertiaryContainer
                        .withValues(alpha: 0.2),
                    iconColor: theme.colorScheme.tertiary,
                    title: 'Background Sync',
                    description:
                        'To maintain continuous secure clipboard syncing, Rift must run in the background without battery optimization restrictions.',
                    infoTag: 'MANDATORY FOR BACKGROUND OPS',
                    actions: [
                      _buildPrimaryButton(
                        _isProcessing ? 'Processing...' : 'Allow Unrestricted',
                        theme,
                        _isProcessing ? null : _finishOnboarding,
                        isProcessing: _isProcessing,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnboardingCard({
    required ThemeData theme,
    required IconData icon,
    required Color iconBgColor,
    required Color iconColor,
    required String title,
    required String description,
    String? infoTag,
    required List<Widget> actions,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
      child: Column(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 48, color: iconColor),
                ),
                const SizedBox(height: 32),
                Text(
                  title,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  description,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (infoTag != null) ...[
                  const SizedBox(height: 32),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      border:
                          Border.all(color: theme.colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: theme.colorScheme.outline),
                        const SizedBox(width: 8),
                        Text(
                          infoTag,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Column(children: actions),
        ],
      ),
    );
  }

  Widget _buildPrimaryButton(
      String text, ThemeData theme, VoidCallback? onPressed,
      {bool isProcessing = false}) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        child: isProcessing
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: theme.colorScheme.onPrimary, strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(text,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              )
            : Text(text,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildOutlinedButton(
      String text, ThemeData theme, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurface,
          side: BorderSide(color: theme.colorScheme.outline),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        child: Text(text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
