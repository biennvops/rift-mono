import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'event_log_screen.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/platform/android_shell.dart';
import '../src/platform/macos_notifications.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _deviceInfo;
  bool _isLoading = true;
  String? _error;
  String _notificationPermissionStatus = 'unknown';
  bool _clipboardNotificationsEnabled = false;

  @override
  void initState() {
    super.initState();
    _fetchDeviceInfo();
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
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _deviceInfo = data as Map<String, dynamic>?;
        _notificationPermissionStatus = notificationStatus;
        _clipboardNotificationsEnabled =
            prefs.getBool(AppPrefs.clipboardNotificationsEnabled) ?? false;
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

  Future<void> _openNotificationSettings() async {
    final theme = Theme.of(context);
    final success = Platform.isAndroid
        ? await AndroidShell.openNotificationSettings()
        : false;
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

  Future<void> _setClipboardNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppPrefs.clipboardNotificationsEnabled, enabled);
    if (!mounted) return;
    setState(() {
      _clipboardNotificationsEnabled = enabled;
    });
  }

  bool get _canOpenNotificationSettings => Platform.isAndroid;

  bool get _notificationsAuthorized =>
      _notificationPermissionStatus == 'authorized';

  IconData get _notificationPermissionIcon => _notificationsAuthorized
      ? Icons.check_circle
      : _notificationPermissionStatus == 'denied'
          ? Icons.cancel
          : Icons.info;

  Color _notificationPermissionColor(ThemeData theme) =>
      _notificationsAuthorized
          ? theme.colorScheme.secondary
          : _notificationPermissionStatus == 'denied'
              ? theme.colorScheme.error
              : theme.colorScheme.outline;

  String get _notificationPermissionSubtitle {
    switch (_notificationPermissionStatus) {
      case 'authorized':
        return 'System notifications enabled';
      case 'denied':
        return 'System notifications are off';
      default:
        return 'Notification status unavailable on this platform';
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

          // General Section
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

          // Identity Section
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

          // Permissions Section
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
                  trailing:
                      !_notificationsAuthorized && _canOpenNotificationSettings
                          ? ElevatedButton(
                              onPressed: _openNotificationSettings,
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
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Platform Specific Section
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
