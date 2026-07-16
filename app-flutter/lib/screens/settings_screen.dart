import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'event_log_screen.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/notification_sync_policy.dart';
import '../src/platform/android_shell.dart';
import '../src/platform/linux_notifications.dart';
import '../src/platform/macos_notifications.dart';
import '../src/platform/notification_route.dart';
import '../src/platform/windows_shell.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _androidTestNotificationPackage = 'com.example.app_flutter';
  static const _androidTestNotificationAppName = 'Rift';
  static const _desktopTestNotificationPackage = 'dev.rift.desktop.test';
  static const _desktopTestNotificationAppName = 'Rift Desktop';
  Map<String, dynamic>? _deviceInfo;
  bool _isLoading = true;
  String? _error;
  String _notificationPermissionStatus = 'unknown';
  String _notificationAccessStatus = 'unknown';
  bool _clipboardNotificationsEnabled = false;
  bool _notificationSyncEnabled = true;
  final TextEditingController _notificationBlacklistController =
      TextEditingController();

  bool get _isDesktopPlatform =>
      WindowsShell.isSupported ||
      LinuxNotifications.isSupported ||
      Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _fetchDeviceInfo();
  }

  @override
  void dispose() {
    _notificationBlacklistController.dispose();
    super.dispose();
  }

  Future<void> _fetchDeviceInfo() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final client = Provider.of<JsonRpcRiftClient>(context, listen: false);
      final data = await client.getDeviceInfo();
      final notificationStatus = await _loadNotificationPermissionStatus();
      final notificationAccessStatus = await _loadNotificationAccessStatus();
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _deviceInfo = data as Map<String, dynamic>?;
        _notificationPermissionStatus = notificationStatus;
        _notificationAccessStatus = notificationAccessStatus;
        _clipboardNotificationsEnabled =
            prefs.getBool(AppPrefs.clipboardNotificationsEnabled) ?? false;
        _notificationSyncEnabled =
            prefs.getBool(AppPrefs.notificationSyncEnabled) ?? true;
        _notificationBlacklistController.text =
            (prefs.getStringList(AppPrefs.notificationSyncBlacklist) ??
                    const <String>[])
                .join('\n');
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = JsonRpcRiftClient.formatDisplayError(e);
        _isLoading = false;
      });
    }
  }

  Future<String> _loadNotificationPermissionStatus() async {
    if (AndroidShell.isSupported) {
      return AndroidShell.getNotificationPermissionStatus();
    }
    if (Platform.isMacOS) {
      return MacOSNotifications.getStatus();
    }
    return 'unknown';
  }

  Future<String> _loadNotificationAccessStatus() async {
    if (AndroidShell.isSupported) {
      return AndroidShell.getNotificationListenerAccessStatus();
    }
    return 'unknown';
  }

  Future<void> _openNotificationSettings() async {
    final theme = Theme.of(context);
    bool success = false;
    if (AndroidShell.isSupported) {
      success = await AndroidShell.openNotificationSettings();
    } else if (Platform.isMacOS) {
      try {
        final direct = await Process.run('open', <String>[
          'x-apple.systempreferences:com.apple.preference.notifications',
        ]);
        success = direct.exitCode == 0;
        if (!success) {
          final fallback = await Process.run('open', <String>[
            '-b',
            'com.apple.systempreferences',
          ]);
          success = fallback.exitCode == 0;
        }
      } catch (_) {
        success = false;
      }
    }
    if (!mounted || success) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Unable to open notification settings on ${Platform.operatingSystem}.',
          style: TextStyle(color: theme.colorScheme.onInverseSurface),
        ),
      ),
    );
  }

  Future<void> _requestMacOSNotifications() async {
    final granted = await MacOSNotifications.request();
    final status = await _loadNotificationPermissionStatus();
    if (!mounted) {
      return;
    }
    setState(() {
      _notificationPermissionStatus = status;
    });
    if (granted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Notifications were not enabled. You can allow them in System Settings > Notifications.',
        ),
      ),
    );
  }

  Future<void> _openNotificationAccessSettings() async {
    final success = AndroidShell.isSupported
        ? await AndroidShell.openNotificationListenerSettings()
        : false;
    if (!mounted || success) return;
    final theme = Theme.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Unable to open Android notification access settings.',
          style: TextStyle(color: theme.colorScheme.onInverseSurface),
        ),
      ),
    );
  }

  Future<void> _showTestNotification() async {
    final client = Provider.of<JsonRpcRiftClient>(context, listen: false);
    final success = await AndroidShell.showTestNotification();
    if (success) {
      final now = DateTime.now().toUtc();
      try {
        await client.notifyLocalNotificationEvent(
          eventType: 'posted',
          payload: <String, Object?>{
            'notificationId':
                'android:$_androidTestNotificationPackage:test:${now.microsecondsSinceEpoch}',
            'packageName': _androidTestNotificationPackage,
            'appName': _androidTestNotificationAppName,
            'title': 'Rift test notification',
            'bodyPreview':
                'Android notifications are enabled. Notification sync still also requires notification access.',
            'postedAt': now.toIso8601String(),
            'isDismissible': true,
            'isOpenable': true,
          },
        );
      } catch (error) {
        debugPrint(
          '[Notification Sync] Failed to mirror Android test notification: $error',
        );
      }
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Sent Android test notification.'
              : 'Unable to send test notification. Enable app notifications first.',
        ),
      ),
    );
  }

  Future<void> _showDesktopTestNotification() async {
    final client = Provider.of<JsonRpcRiftClient>(context, listen: false);
    final now = DateTime.now().toUtc();
    final title = 'Rift desktop test notification';
    final body = 'Desktop notification sync is active for trusted peers.';
    bool shown = false;

    if (WindowsShell.isSupported) {
      shown = await WindowsShell.showNotification(
        title: title,
        body: body,
        route: NotificationRoute.historyNotifications,
        payload: const <String, Object?>{'testNotification': true},
      );
    } else if (LinuxNotifications.isSupported) {
      shown = await LinuxNotifications.show(
        title: title,
        body: body,
        route: NotificationRoute.historyNotifications,
        payload: const <String, Object?>{'testNotification': true},
      );
    } else if (Platform.isMacOS) {
      shown = await MacOSNotifications.show(
        title: title,
        body: body,
        route: NotificationRoute.historyNotifications,
        payload: const <String, Object?>{'testNotification': true},
      );
    }

    if (shown) {
      try {
        await client.notifyLocalNotificationEvent(
          eventType: 'posted',
          payload: <String, Object?>{
            'notificationId':
                'desktop:$_desktopTestNotificationPackage:test:${now.microsecondsSinceEpoch}',
            'sourcePlatform': Platform.isWindows
                ? 'windows'
                : Platform.isMacOS
                    ? 'macos'
                    : 'linux',
            'packageName': _desktopTestNotificationPackage,
            'appName': _desktopTestNotificationAppName,
            'title': title,
            'bodyPreview': body,
            'postedAt': now.toIso8601String(),
            'isDismissible': false,
            'isOpenable': false,
          },
        );
      } catch (error) {
        debugPrint(
          '[Notification Sync] Failed to mirror desktop test notification: $error',
        );
      }
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          shown
              ? 'Sent desktop test notification.'
              : 'Unable to send desktop test notification on this platform.',
        ),
      ),
    );
  }

  Future<void> _setClipboardNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppPrefs.clipboardNotificationsEnabled, enabled);
    if (!mounted) return;
    setState(() {
      _clipboardNotificationsEnabled = enabled;
    });
  }

  List<String> _notificationBlacklistPackages() {
    return _notificationBlacklistController.text
        .split(RegExp(r'[\n,]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Future<void> _persistNotificationSyncPolicy() async {
    final blacklist = _notificationBlacklistPackages();
    await persistNotificationSyncPolicyPreferences(
      enabled: _notificationSyncEnabled,
      blacklistedPackages: blacklist,
    );
    if (!mounted) {
      return;
    }
    final client = Provider.of<JsonRpcRiftClient>(context, listen: false);
    if (!client.isConnected) {
      return;
    }
    try {
      await client.updateNotificationSyncPolicy(
        enabled: _notificationSyncEnabled,
        blacklistedPackages: blacklist,
      );
    } catch (error) {
      if (JsonRpcRiftClient.isMethodNotFoundError(error)) {
        return;
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(error))),
      );
    }
  }

  bool get _canManageNotificationSettings =>
      AndroidShell.isSupported || Platform.isMacOS;

  bool get _notificationsAuthorized =>
      _notificationPermissionStatus == 'authorized';

  bool get _notificationAccessAuthorized =>
      _notificationAccessStatus == 'authorized';

  IconData get _notificationPermissionIcon => _notificationsAuthorized
      ? Icons.check_circle
      : _notificationPermissionStatus == 'denied'
          ? Icons.cancel
          : Icons.info;

  IconData get _notificationAccessIcon => _notificationAccessAuthorized
      ? Icons.check_circle
      : _notificationAccessStatus == 'denied'
          ? Icons.cancel
          : Icons.info;

  Color _notificationPermissionColor(ThemeData theme) =>
      _notificationsAuthorized
          ? theme.colorScheme.secondary
          : _notificationPermissionStatus == 'denied'
              ? theme.colorScheme.error
              : theme.colorScheme.outline;

  Color _notificationAccessColor(ThemeData theme) =>
      _notificationAccessAuthorized
          ? theme.colorScheme.secondary
          : _notificationAccessStatus == 'denied'
              ? theme.colorScheme.error
              : theme.colorScheme.outline;

  String get _notificationPermissionSubtitle {
    switch (_notificationPermissionStatus) {
      case 'authorized':
        return 'System notifications enabled';
      case 'denied':
        return 'System notifications are off';
      case 'notDetermined':
        return Platform.isMacOS
            ? 'Permission has not been requested yet'
            : 'Notification permission not granted yet';
      case 'unknown':
        return Platform.isMacOS
            ? 'Unable to read macOS notification permission state'
            : 'Notification status unavailable on this platform';
      default:
        return 'Notification status: $_notificationPermissionStatus';
    }
  }

  String get _notificationPermissionActionLabel {
    if (Platform.isMacOS && _notificationPermissionStatus == 'notDetermined') {
      return 'ALLOW';
    }
    return 'OPEN SETTINGS';
  }

  Future<void> _handleNotificationPermissionAction() async {
    if (Platform.isMacOS && _notificationPermissionStatus == 'notDetermined') {
      await _requestMacOSNotifications();
      return;
    }
    await _openNotificationSettings();
  }

  String get _notificationAccessSubtitle {
    if (!AndroidShell.isSupported) {
      return 'Notification access is only required on Android';
    }

    switch (_notificationAccessStatus) {
      case 'authorized':
        return 'Android notification access enabled for sync';
      case 'denied':
        return 'Android notification access is off';
      default:
        return 'Notification access status unavailable';
    }
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontFamily: 'JetBrains Mono',
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.0,
            ),
      ),
    );
  }

  Widget _buildListTile({
    required String title,
    required String subtitle,
    Widget? leading,
    Widget? trailing,
    VoidCallback? onTap,
    bool isError = false,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              leading,
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: isError
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isError
                          ? theme.colorScheme.error.withValues(alpha: 0.8)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 16),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    return _buildListTile(
      leading: Icon(icon, color: color),
      title: title,
      subtitle: subtitle,
      trailing: trailing,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
            title: const Text('Settings',
                style: TextStyle(
                    fontFamily: 'Inter', fontWeight: FontWeight.bold))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final displayName = _deviceInfo?['displayName']?.toString() ??
        _deviceInfo?['deviceId']?.toString() ??
        'Unknown Device';
    final deviceId = _deviceInfo?['deviceId']?.toString() ?? 'Unknown';
    final fingerprint = _deviceInfo?['fingerprint']?.toString() ?? 'Unknown';
    final implementationId =
        _deviceInfo?['implementationId']?.toString() ?? 'Unavailable';
    final protocolVersion =
        _deviceInfo?['protocolVersion']?.toString() ?? 'Unavailable';
    final localNetworkSubtitle = Platform.isAndroid || Platform.isMacOS
        ? 'Used during discovery and pairing'
        : 'Managed by the local daemon';
    final backgroundExecSubtitle = Platform.isAndroid
        ? 'Rift uses a foreground service; some vendors may still restrict background work'
        : 'Handled by the desktop session and local daemon';

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 100),
        children: [
          Text(
            'Settings',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 32),
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              color: theme.colorScheme.errorContainer,
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            ),
            const SizedBox(height: 24),
          ],
          _buildSectionHeader('General'),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildListTile(
                  title: 'Device name',
                  subtitle: displayName,
                  trailing: Icon(Icons.edit, color: theme.colorScheme.outline),
                  onTap: () {},
                ),
                _buildListTile(
                  title: 'Theme',
                  subtitle: 'System default',
                  trailing: Icon(Icons.chevron_right,
                      color: theme.colorScheme.outline),
                  onTap: () {},
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          _buildSectionHeader('Identity'),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildListTile(
                  title: 'Device ID',
                  subtitle: deviceId,
                ),
                _buildListTile(
                  title: 'Fingerprint',
                  subtitle: fingerprint,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          _buildSectionHeader('Permissions'),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildStatusRow(
                  icon: Icons.check_circle,
                  color: theme.colorScheme.secondary,
                  title: 'Local Network',
                  subtitle: localNetworkSubtitle,
                ),
                _buildStatusRow(
                  icon: _notificationPermissionIcon,
                  color: _notificationPermissionColor(theme),
                  title: 'Notifications',
                  subtitle: _notificationPermissionSubtitle,
                  trailing: !_notificationsAuthorized &&
                          _canManageNotificationSettings
                      ? ElevatedButton(
                          onPressed: _handleNotificationPermissionAction,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                          ),
                          child: Text(
                            _notificationPermissionActionLabel,
                            style: const TextStyle(
                              fontFamily: 'JetBrains Mono',
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      : null,
                ),
                if (AndroidShell.isSupported)
                  _buildStatusRow(
                    icon: _notificationAccessIcon,
                    color: _notificationAccessColor(theme),
                    title: 'Notification access',
                    subtitle: _notificationAccessSubtitle,
                    trailing: !_notificationAccessAuthorized
                        ? ElevatedButton(
                            onPressed: _openNotificationAccessSettings,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                            ),
                            child: const Text(
                              'OPEN SETTINGS',
                              style: TextStyle(
                                fontFamily: 'JetBrains Mono',
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : null,
                  ),
                _buildStatusRow(
                  icon: Icons.info,
                  color: theme.colorScheme.outline,
                  title: 'Background Exec',
                  subtitle: backgroundExecSubtitle,
                ),
                Material(
                  color: Colors.transparent,
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    secondary: Icon(
                      Icons.content_paste,
                      color: theme.colorScheme.outline,
                    ),
                    title: const Text('Clipboard received notifications'),
                    subtitle: Text(
                      'Off by default. Show a system notification when automatic clipboard sync receives content.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: _clipboardNotificationsEnabled,
                    onChanged: _setClipboardNotificationsEnabled,
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    secondary: Icon(
                      Icons.notifications_active,
                      color: theme.colorScheme.outline,
                    ),
                    title: const Text('Android notification sync'),
                    subtitle: Text(
                      _notificationAccessAuthorized
                          ? 'On by default. Mirror Android notifications to trusted desktop devices only.'
                          : 'On by default, but Android notification access must be enabled before sync can work.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: _notificationSyncEnabled,
                    onChanged: (enabled) async {
                      setState(() {
                        _notificationSyncEnabled = enabled;
                      });
                      await _persistNotificationSyncPolicy();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TextField(
                    controller: _notificationBlacklistController,
                    minLines: 2,
                    maxLines: 4,
                    onChanged: (_) {
                      unawaited(_persistNotificationSyncPolicy());
                    },
                    decoration: const InputDecoration(
                      labelText: 'Notification blacklist',
                      helperText:
                          'One Android package per line. Blacklisted apps stay local.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (AndroidShell.isSupported)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showTestNotification,
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: const Text('Test notification'),
                      ),
                    ),
                  ),
                if (_isDesktopPlatform)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showDesktopTestNotification,
                        icon: const Icon(Icons.desktop_windows_outlined),
                        label: const Text('Test desktop sync'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          _buildSectionHeader('System Checks'),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (Platform.isAndroid) ...[
                  Container(
                    color: theme.colorScheme.surfaceContainer,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Android Clipboard Monitoring',
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Rift uses the platform clipboard APIs and foreground service flow for clipboard syncing. Accessibility Service is not required.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
                if (Platform.isLinux) ...[
                  Container(
                    color: theme.colorScheme.surfaceContainer,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Linux Daemon Dependencies',
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.done,
                                size: 16, color: theme.colorScheme.secondary),
                            const SizedBox(width: 8),
                            Text('avahi-daemon: running',
                                style: theme.textTheme.labelMedium?.copyWith(
                                    fontFamily: 'JetBrains Mono',
                                    color: theme.colorScheme.secondary)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.done,
                                size: 16, color: theme.colorScheme.secondary),
                            const SizedBox(width: 8),
                            Text('appindicator: supported',
                                style: theme.textTheme.labelMedium?.copyWith(
                                    fontFamily: 'JetBrains Mono',
                                    color: theme.colorScheme.secondary)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (!Platform.isAndroid && !Platform.isLinux) ...[
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                        'No platform-specific checks for ${Platform.operatingSystem} yet.',
                        style: theme.textTheme.bodyMedium),
                  ),
                ],
              ],
            ),
          ),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 32),
            _buildSectionHeader('Clipboard'),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  _buildListTile(
                    title: 'Background clipboard monitoring',
                    subtitle:
                        'Uses Rift foreground service when background sync is active',
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 40),
          _buildSectionHeader('Trust Store'),
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.folder),
            label: const Text('MANAGE TRUST STORE',
                style: TextStyle(
                    fontFamily: 'JetBrains Mono', fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              foregroundColor: theme.colorScheme.primary,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              backgroundColor: theme.colorScheme.surfaceContainer,
            ),
          ),
          const SizedBox(height: 32),
          _buildSectionHeader('About Application'),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildListTile(
                  title: 'Implementation',
                  subtitle: implementationId,
                ),
                _buildListTile(
                  title: 'Protocol version',
                  subtitle: protocolVersion,
                ),
                _buildListTile(
                  title: 'Event log',
                  subtitle: 'Open the full local audit trail',
                  trailing: Icon(Icons.chevron_right,
                      color: theme.colorScheme.outline),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const EventLogScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
