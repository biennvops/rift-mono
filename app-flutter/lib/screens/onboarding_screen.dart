import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/ipc/json_rpc_client.dart';
import '../src/platform/android_shell.dart';
import '../src/platform/ios_notifications.dart';
import '../src/platform/macos_notifications.dart';
import '../src/ui/app_shell.dart';
import '../widgets/rift_snackbar.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final PageController _pageController = PageController();
  late final AnimationController _introController;

  int _currentPage = 0;
  bool _isFinishing = false;
  bool? _localNetworkGranted;
  bool? _notificationPermissionGranted;
  bool? _notificationAccessGranted;
  bool _permissionPromptsCompleted = false;
  bool _permissionPromptsRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..forward();
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _introController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions();
    }
  }

  Future<void> _refreshPermissions() async {
    final localNetworkGranted = await _checkLocalNetwork();
    final notificationStatus = AndroidShell.isSupported
        ? await AndroidShell.getNotificationPermissionStatus()
        : IOSNotifications.isSupported
            ? await IOSNotifications.getPermissionStatus()
            : await MacOSNotifications.getStatus();
    final notificationAccessStatus = AndroidShell.isSupported
        ? await AndroidShell.getNotificationListenerAccessStatus()
        : 'authorized';
    if (!mounted) return;
    setState(() {
      _localNetworkGranted = localNetworkGranted;
      _notificationPermissionGranted = notificationStatus == 'authorized';
      _notificationAccessGranted = notificationAccessStatus == 'authorized';
    });
  }

  Future<bool> _checkLocalNetwork() async {
    try {
      await context.read<JsonRpcRiftClient>().startDiscovery();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requestLocalNetwork() async {
    final granted = await _checkLocalNetwork();
    if (!mounted) return;
    setState(() => _localNetworkGranted = granted);
    if (!granted) {
      RiftSnackbar.show(
        context: context,
        message:
            'Local network access is still unavailable. Enable it in System Settings to discover nearby devices.',
        type: RiftSnackbarType.warning,
      );
    }
  }

  Future<void> _requestNotificationPermission() async {
    final granted = AndroidShell.isSupported
        ? await AndroidShell.requestNotificationPermission()
        : IOSNotifications.isSupported
            ? await IOSNotifications.requestPermission()
            : await MacOSNotifications.request();
    if (!mounted) return;
    setState(() => _notificationPermissionGranted = granted);
  }

  Future<void> _requestNotificationAccess() async {
    final opened = await AndroidShell.openNotificationListenerSettings();
    if (!mounted || opened) return;
    RiftSnackbar.show(
      context: context,
      message: 'Unable to open Android notification access settings.',
      type: RiftSnackbarType.warning,
    );
  }

  void _nextPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _previousPage() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<bool> _askPermission({
    required IconData icon,
    required String title,
    required String body,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          icon: Icon(icon, color: theme.colorScheme.primary, size: 32),
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Enable'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _runPermissionPrompts() async {
    if (_permissionPromptsRunning || _permissionPromptsCompleted) return;
    _permissionPromptsRunning = true;

    final enableLocalNetwork = await _askPermission(
      icon: Icons.wifi_tethering,
      title: 'Allow local network?',
      body:
          'This lets Rift discover and connect to nearby devices. Internet access is not required.',
    );
    if (!mounted) return;
    if (enableLocalNetwork) await _requestLocalNetwork();

    if (!mounted) return;
    final enableNotifications = await _askPermission(
      icon: Icons.notifications_outlined,
      title: 'Allow app notifications?',
      body:
          'Rift can notify you about transfers, security events, and device connections.',
    );
    if (!mounted) return;
    if (enableNotifications) await _requestNotificationPermission();

    if (mounted && AndroidShell.isSupported) {
      final enableNotificationSync = await _askPermission(
        icon: Icons.sync,
        title: 'Enable notification sync?',
        body:
            'Android notification access lets Rift mirror notifications to your trusted devices.',
      );
      if (!mounted) return;
      if (enableNotificationSync) await _requestNotificationAccess();
    }

    if (!mounted) return;
    setState(() {
      _permissionPromptsRunning = false;
      _permissionPromptsCompleted = true;
    });
  }

  Future<void> _finishOnboarding() async {
    if (_isFinishing) return;
    setState(() => _isFinishing = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_completed_onboarding', true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AppShell()),
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
            if (_currentPage > 0) _buildProgressHeader(theme),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (page) {
                  setState(() => _currentPage = page);
                  if (page == 2) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _runPermissionPrompts();
                    });
                  }
                },
                children: [
                  _buildWelcomePage(theme),
                  _buildAboutPage(theme),
                  _buildPermissionsPage(theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _previousPage,
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 4),
          Image.asset(
            'assets/images/rift_logo.png',
            width: 32,
            height: 32,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 10),
          Text(
            'Rift',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            '${_currentPage + 1} / 3',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomePage(ThemeData theme) {
    final logoAnimation = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0, 0.45, curve: Curves.easeOutBack),
    );
    final titleAnimation = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.35, 0.7, curve: Curves.easeOut),
    );

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: AnimatedBuilder(
            animation: _introController,
            builder: (context, child) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FadeTransition(
                    opacity: logoAnimation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.72, end: 1)
                          .animate(logoAnimation),
                      child: Image.asset(
                        'assets/images/rift_logo.png',
                        width: 132,
                        height: 132,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FadeTransition(
                    opacity: titleAnimation,
                    child: Column(
                      children: [
                        Text(
                          'Rift',
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Your devices, working together.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _introController.value,
                      minHeight: 4,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: 24),
                  AnimatedOpacity(
                    opacity: _introController.isCompleted ? 1 : 0,
                    duration: const Duration(milliseconds: 240),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed:
                            _introController.isCompleted ? _nextPage : null,
                        child: const Text('Get started'),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAboutPage(ThemeData theme) {
    return _OnboardingScrollPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Continuity without the cloud',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Rift connects your trusted devices directly over your local network. No account, cloud server, or Internet connection is required.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          _FeatureCard(
            icon: Icons.content_copy_outlined,
            title: 'Clipboard continuity',
            body: 'Copy text or images on one device and use them on another.',
          ),
          const SizedBox(height: 8),
          _FeatureCard(
            icon: Icons.send_outlined,
            title: 'Direct file transfer',
            body: 'Send files securely between trusted devices on your LAN.',
          ),
          const SizedBox(height: 8),
          _FeatureCard(
            icon: Icons.notifications_active_outlined,
            title: 'Notifications and media',
            body:
                'Mirror alerts and control media when the platform permissions are enabled.',
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.wifi, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Internet is optional. Devices only need to be reachable on the same local network.',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _nextPage,
              child: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionsPage(ThemeData theme) {
    return _OnboardingScrollPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enable the features you want',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _permissionPromptsCompleted
                ? 'Your choices are saved for this setup. Permissions can be changed later in Settings.'
                : 'Choose Enable or Not now for each permission to continue.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _PermissionCard(
            icon: Icons.wifi_tethering,
            title: 'Local network',
            body: 'Discover and connect to nearby Rift devices.',
            granted: _localNetworkGranted,
            actionLabel: 'Enable',
            onPressed: _requestLocalNetwork,
          ),
          const SizedBox(height: 12),
          _PermissionCard(
            icon: Icons.notifications_outlined,
            title: 'App notifications',
            body: 'Receive transfer, security, and connection alerts.',
            granted: _notificationPermissionGranted,
            actionLabel: 'Enable',
            onPressed: _requestNotificationPermission,
          ),
          if (AndroidShell.isSupported) ...[
            const SizedBox(height: 12),
            _PermissionCard(
              icon: Icons.sync,
              title: 'Notification sync',
              body: 'Mirror Android notifications to trusted devices.',
              granted: _notificationAccessGranted,
              actionLabel: 'Open settings',
              onPressed: _requestNotificationAccess,
            ),
          ],
          const SizedBox(height: 12),
          const _PermissionCard(
            icon: Icons.cloud_off_outlined,
            title: 'Internet',
            body: 'Not required. Rift keeps device-to-device actions local.',
            granted: true,
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: !_permissionPromptsCompleted || _isFinishing
                  ? null
                  : _finishOnboarding,
              icon: _isFinishing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
              label: Text(_isFinishing ? 'Opening Rift…' : 'Open Rift'),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingScrollPage extends StatelessWidget {
  const _OnboardingScrollPage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: child,
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.granted,
    this.actionLabel,
    this.onPressed,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool? granted;
  final String? actionLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGranted = granted == true;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isGranted
                  ? theme.colorScheme.secondaryContainer
                  : theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: isGranted
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (granted == null)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (isGranted)
            Icon(Icons.check_circle, color: theme.colorScheme.secondary)
          else
            TextButton(
              onPressed: onPressed,
              child: Text(actionLabel ?? 'Enable'),
            ),
        ],
      ),
    );
  }
}
