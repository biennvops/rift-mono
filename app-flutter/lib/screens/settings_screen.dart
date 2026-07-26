import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

import '../constants.dart';
import 'event_log_screen.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/notification_sync_policy.dart';
import '../src/platform/android_shell.dart';
import '../src/platform/linux_notifications.dart';
import '../src/platform/macos_notifications.dart';
import '../src/platform/notification_route.dart';
import '../src/platform/windows_shell.dart';
import '../widgets/rift_snackbar.dart';
import '../widgets/premium_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _activeTab = 'general';
  static const Duration _notificationPolicyDebounce = Duration(milliseconds: 300);
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
  Timer? _notificationPolicyDebounceTimer;
  String? _defaultDownloadPath;
  double _sidebarWidth = 220.0;

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
    _notificationPolicyDebounceTimer?.cancel();
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
        _defaultDownloadPath = prefs.getString(AppPrefs.defaultDownloadPath);
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
    RiftSnackbar.show(
      context: context,
      message: 'Unable to open notification settings on ${Platform.operatingSystem}.',
      type: RiftSnackbarType.error,
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
    RiftSnackbar.show(
      context: context,
      message: 'Notifications were not enabled. You can allow them in System Settings > Notifications.',
      type: RiftSnackbarType.warning,
    );
  }

  Future<void> _openNotificationAccessSettings() async {
    final success = AndroidShell.isSupported
        ? await AndroidShell.openNotificationListenerSettings()
        : false;
    if (!mounted || success) return;
    RiftSnackbar.show(
      context: context,
      message: 'Unable to open Android notification access settings.',
      type: RiftSnackbarType.error,
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
            'bodyPreview': 'If you see this notification, sync is working.',
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
    RiftSnackbar.show(
      context: context,
      message: success
          ? 'Sent Android test notification.'
          : 'Unable to send test notification. Enable app notifications first.',
      type: success ? RiftSnackbarType.success : RiftSnackbarType.warning,
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
    RiftSnackbar.show(
      context: context,
      message: shown
          ? 'Sent desktop test notification.'
          : 'Unable to send desktop test notification on this platform.',
      type: shown ? RiftSnackbarType.success : RiftSnackbarType.warning,
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
      RiftSnackbar.show(
        context: context,
        message: JsonRpcRiftClient.formatDisplayError(error),
        type: RiftSnackbarType.error,
      );
    }
  }

  void _scheduleNotificationSyncPolicyPersist() {
    _notificationPolicyDebounceTimer?.cancel();
    _notificationPolicyDebounceTimer = Timer(
      _notificationPolicyDebounce,
      _persistNotificationSyncPolicy,
    );
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

  Widget _buildTabRail(ThemeData theme, bool isSmallScreen) {
    final tabs = [
      ('general', 'General', Icons.tune),
      ('identity', 'Identity', Icons.badge_outlined),
      ('permissions', 'Permissions', Icons.security),
      ('system', 'System Checks', Icons.check_box_outlined),
      ('filetransfer', 'File Transfer', Icons.folder_shared_outlined),
      ('trust', 'Trust Store', Icons.shield_outlined),
      ('about', 'About', Icons.info_outline),
    ];

    return Container(
      width: isSmallScreen ? 64 : _sidebarWidth,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.all(8),
      child: ListView(
        children: tabs.map((tab) {
          final id = tab.$1;
          final label = tab.$2;
          final icon = tab.$3;
          final isActive = _activeTab == id;

          final itemContent = Row(
            mainAxisAlignment: isSmallScreen ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 18,
                color: isActive ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              ),
              if (!isSmallScreen) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: isActive ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          );

          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Material(
              color: isActive ? theme.colorScheme.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                onTap: () => setState(() => _activeTab = id),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 0 : 10, vertical: 10),
                  decoration: isActive ? BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ) : null,
                  child: isSmallScreen
                      ? Tooltip(message: label, child: itemContent)
                      : itemContent,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBadge(ThemeData theme, String text, Color bgColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 9.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.6,
          color: textColor,
        ),
      ),
    );
  }

  Widget _buildAndroidBadge(ThemeData theme) => _buildBadge(theme, 'Android', const Color(0xFF6E3FB0).withValues(alpha: 0.10), const Color(0xFF6E3FB0));
  Widget _buildDesktopBadge(ThemeData theme) => _buildBadge(theme, 'Desktop', const Color(0xFF3636C5).withValues(alpha: 0.10), const Color(0xFF3636C5));
  Widget _buildLinuxBadge(ThemeData theme) => _buildBadge(theme, 'Linux', const Color(0xFF3636C5).withValues(alpha: 0.10), const Color(0xFF3636C5));
  Widget _buildGrantedChip(ThemeData theme) => _buildBadge(theme, 'Granted', const Color(0xFF12744F).withValues(alpha: 0.10), const Color(0xFF12744F));

  Widget _buildSuccessIcon(ThemeData theme) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: const Color(0xFF12744F).withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check, size: 15, color: Color(0xFF12744F)),
    );
  }

  Widget _buildIconButton(ThemeData theme, IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }

  void _copyToClipboard(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    RiftSnackbar.show(
      context: context,
      message: message,
      type: RiftSnackbarType.success,
    );
  }

  Widget _buildPanelHeader(ThemeData theme, String title, String desc, {Widget? badge}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 8),
              badge,
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          desc,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildGroupLabel(ThemeData theme, String label, {Widget? badge}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 16),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              fontFamily: 'JetBrains Mono',
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: 8),
            badge,
          ],
        ],
      ),
    );
  }

  Widget _buildRow({
    required ThemeData theme,
    required String title,
    required String subtitle,
    Widget? leadingIcon,
    Widget? trailing,
    Widget? titleBadge,
    bool isMonoTitle = false,
    bool isMonoSubtitle = false,
    VoidCallback? onTap,
  }) {
    final content = Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          if (leadingIcon != null) ...[
            leadingIcon,
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: isMonoTitle ? 'JetBrains Mono' : null,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (titleBadge != null) ...[
                      const SizedBox(width: 8),
                      titleBadge,
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: isMonoSubtitle ? 'JetBrains Mono' : null,
                    color: theme.colorScheme.onSurfaceVariant,
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
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: content,
      );
    }
    return content;
  }

  Widget _buildGeneralPanel(ThemeData theme, String displayName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'General', 'Basic identity and pairing preferences for this device.'),
        _buildRow(
          theme: theme,
          title: 'Device name',
          subtitle: displayName,
          trailing: _buildIconButton(theme, Icons.edit, 'Rename device', () => _showEditDeviceNameDialog(displayName)),
          onTap: () => _showEditDeviceNameDialog(displayName),
        ),
        _buildRow(
          theme: theme,
          title: 'Pair by IP',
          subtitle: 'Manually pair with a device using its IP address',
          trailing: _buildIconButton(theme, Icons.router, 'Pair by IP', _showManualPairDialog),
          onTap: _showManualPairDialog,
        ),
        _buildRow(
          theme: theme,
          title: 'Theme',
          subtitle: 'System default',
          trailing: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
          onTap: () {},
        ),
      ],
    );
  }

  Widget _buildIdentityPanel(ThemeData theme, String deviceId, String fingerprint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'Identity', 'Your device\'s unique cryptographic identity, used to verify trust with peers.'),
        _buildRow(
          theme: theme,
          title: 'Device ID',
          subtitle: deviceId,
          isMonoSubtitle: true,
          trailing: _buildIconButton(theme, Icons.copy, 'Copy Device ID', () => _copyToClipboard(deviceId, 'Device ID copied to clipboard')),
        ),
        _buildRow(
          theme: theme,
          title: 'Fingerprint',
          subtitle: fingerprint,
          isMonoSubtitle: true,
          trailing: _buildIconButton(theme, Icons.copy, 'Copy Fingerprint', () => _copyToClipboard(fingerprint, 'Fingerprint copied to clipboard')),
        ),
      ],
    );
  }

  Widget _buildPermissionsPanel(ThemeData theme, String localNetworkSubtitle, String backgroundExecSubtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'Permissions & System Sync', 'Control what Rift can access on this device and how notifications mirror across your devices.'),
        _buildGroupLabel(theme, 'SYSTEM ACCESS'),
        _buildRow(
          theme: theme,
          title: 'Local Network',
          subtitle: localNetworkSubtitle,
          leadingIcon: _buildSuccessIcon(theme),
        ),
        _buildRow(
          theme: theme,
          title: 'Notifications',
          subtitle: _notificationPermissionSubtitle,
          leadingIcon: Icon(_notificationPermissionIcon, color: _notificationPermissionColor(theme), size: 20),
          trailing: _notificationsAuthorized
              ? _buildGrantedChip(theme)
              : (_canManageNotificationSettings
                  ? ElevatedButton(
                      onPressed: _handleNotificationPermissionAction,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                      child: Text(_notificationPermissionActionLabel, style: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 12, fontWeight: FontWeight.bold)),
                    )
                  : null),
        ),
        if (AndroidShell.isSupported)
          _buildRow(
            theme: theme,
            title: 'Notification access',
            subtitle: _notificationAccessSubtitle,
            titleBadge: _buildAndroidBadge(theme),
            leadingIcon: Icon(_notificationAccessIcon, color: _notificationAccessColor(theme), size: 20),
            trailing: _notificationAccessAuthorized
                ? _buildGrantedChip(theme)
                : ElevatedButton(
                    onPressed: _openNotificationAccessSettings,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    child: const Text('OPEN SETTINGS', style: TextStyle(fontFamily: 'JetBrains Mono', fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
          ),
        _buildRow(
          theme: theme,
          title: 'Background Exec',
          subtitle: backgroundExecSubtitle,
        ),
        _buildGroupLabel(theme, 'NOTIFICATION SYNC'),
        _buildRow(
          theme: theme,
          title: 'Clipboard received notifications',
          subtitle: 'Off by default. Shows a system notification when automatic clipboard sync receives content.',
          trailing: Switch(
            value: _clipboardNotificationsEnabled,
            onChanged: _setClipboardNotificationsEnabled,
          ),
        ),
        _buildRow(
          theme: theme,
          title: 'Android notification sync',
          subtitle: _notificationAccessAuthorized
              ? 'Mirror Android notifications to trusted desktop devices only.'
              : 'On by default, but Android notification access must be enabled before sync can work.',
          titleBadge: _buildAndroidBadge(theme),
          trailing: Switch(
            value: _notificationSyncEnabled,
            onChanged: (enabled) async {
              setState(() {
                _notificationSyncEnabled = enabled;
              });
              await _persistNotificationSyncPolicy();
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Notification blacklist', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
              const SizedBox(height: 2),
              Text('One Android package per line. Blacklisted apps stay local.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              TextField(
                controller: _notificationBlacklistController,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 13),
                onChanged: (_) => _scheduleNotificationSyncPolicyPersist(),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerLow,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: theme.colorScheme.outlineVariant)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (AndroidShell.isSupported)
                OutlinedButton.icon(
                  onPressed: _showTestNotification,
                  icon: const Icon(Icons.notifications_active_outlined, size: 16),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Test notification '),
                      _buildAndroidBadge(theme),
                    ],
                  ),
                ),
              if (_isDesktopPlatform)
                OutlinedButton.icon(
                  onPressed: _showDesktopTestNotification,
                  icon: const Icon(Icons.desktop_windows_outlined, size: 16),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Test desktop sync '),
                      _buildDesktopBadge(theme),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSystemPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(
          theme,
          'System Checks',
          'Platform-level dependencies Rift needs to discover and sync with other devices.',
          badge: Platform.isLinux ? _buildLinuxBadge(theme) : (Platform.isAndroid ? _buildAndroidBadge(theme) : _buildDesktopBadge(theme)),
        ),
        if (Platform.isLinux) ...[
          _buildRow(theme: theme, title: 'avahi-daemon', subtitle: 'running', leadingIcon: _buildSuccessIcon(theme), isMonoTitle: true, isMonoSubtitle: true),
          _buildRow(theme: theme, title: 'appindicator', subtitle: 'supported', leadingIcon: _buildSuccessIcon(theme), isMonoTitle: true, isMonoSubtitle: true),
        ] else if (Platform.isAndroid) ...[
          _buildRow(theme: theme, title: 'Android Clipboard Monitoring', subtitle: 'Rift uses platform clipboard APIs and foreground service flow. Accessibility Service is not required.', leadingIcon: _buildSuccessIcon(theme)),
        ] else ...[
          _buildRow(theme: theme, title: 'Platform check', subtitle: 'No platform-specific checks for ${Platform.operatingSystem} yet.'),
        ],
        if (Platform.isAndroid) ...[
          _buildGroupLabel(theme, 'CLIPBOARD', badge: _buildAndroidBadge(theme)),
          _buildRow(theme: theme, title: 'Background clipboard monitoring', subtitle: 'Uses Rift foreground service when background sync is active'),
        ],
      ],
    );
  }

  Widget _buildFileTransferPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'File Transfer', 'Where files received from trusted devices are saved.'),
        _buildRow(
          theme: theme,
          title: 'Default Download Location',
          subtitle: _defaultDownloadPath ?? 'Downloads/Rift (System Default)',
          isMonoSubtitle: true,
          trailing: _buildIconButton(theme, Icons.folder_open, 'Choose folder', _pickDefaultDownloadPath),
          onTap: _pickDefaultDownloadPath,
        ),
      ],
    );
  }

  Widget _buildTrustPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'Trust Store', 'Manage the cryptographic keys and certificates of every device you\'ve trusted.'),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              RiftSnackbar.show(context: context, message: 'Trust Store management is under development.', type: RiftSnackbarType.info);
            },
            icon: const Icon(Icons.folder_outlined, size: 18),
            label: const Text('MANAGE TRUST STORE', style: TextStyle(fontFamily: 'JetBrains Mono', fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAboutPanel(ThemeData theme, String implementationId, String protocolVersion) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'About Application', 'Build, protocol, and audit information.'),
        _buildRow(theme: theme, title: 'Implementation', subtitle: implementationId),
        _buildRow(theme: theme, title: 'Protocol version', subtitle: protocolVersion, isMonoSubtitle: true),
        _buildRow(
          theme: theme,
          title: 'Event log',
          subtitle: 'Open the full local audit trail',
          trailing: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const EventLogScreen(),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildActivePanel(
    ThemeData theme,
    String displayName,
    String deviceId,
    String fingerprint,
    String implementationId,
    String protocolVersion,
    String localNetworkSubtitle,
    String backgroundExecSubtitle,
  ) {
    Widget content;
    switch (_activeTab) {
      case 'identity':
        content = _buildIdentityPanel(theme, deviceId, fingerprint);
        break;
      case 'permissions':
        content = _buildPermissionsPanel(theme, localNetworkSubtitle, backgroundExecSubtitle);
        break;
      case 'system':
        content = _buildSystemPanel(theme);
        break;
      case 'filetransfer':
        content = _buildFileTransferPanel(theme);
        break;
      case 'trust':
        content = _buildTrustPanel(theme);
        break;
      case 'about':
        content = _buildAboutPanel(theme, implementationId, protocolVersion);
        break;
      case 'general':
      default:
        content = _buildGeneralPanel(theme, displayName);
        break;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            const SizedBox(height: 16),
          ],
          content,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
            automaticallyImplyLeading: widget.onClose == null,
            titleSpacing: widget.onClose != null ? 16 : null,
            title: const Text('Settings',
                style: TextStyle(
                    fontFamily: 'Inter', fontSize: 22, fontWeight: FontWeight.w700)),
            actions: widget.onClose != null
                ? [
                    IconButton(
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close),
                      tooltip: 'Close Settings',
                    ),
                    const SizedBox(width: 8),
                  ]
                : null),
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

    final isSmallScreen = MediaQuery.of(context).size.width < 720;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: widget.onClose == null,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        titleSpacing: widget.onClose != null ? 16 : null,
        title: Text(
          'Settings',
          style: theme.textTheme.titleLarge?.copyWith(
            fontFamily: 'Inter',
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        actions: [
          if (widget.onClose != null) ...[
            IconButton(
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Close Settings',
            ),
            const SizedBox(width: 8),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTabRail(theme, isSmallScreen),
          if (!isSmallScreen)
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (details) {
                  setState(() {
                    _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(160.0, 400.0);
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
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            VerticalDivider(width: 1, thickness: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(
            child: _buildActivePanel(
              theme,
              displayName,
              deviceId,
              fingerprint,
              implementationId,
              protocolVersion,
              localNetworkSubtitle,
              backgroundExecSubtitle,
            ),
          ),
        ],
      ),
    );
  }

  void _showEditDeviceNameDialog(String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) {
        return PremiumDialog(
          title: 'Edit Device Name',
          subtitle: 'Change how this device appears to others on the network.',
          content: PremiumTextField(
            controller: controller,
            label: 'Device Name',
            hint: 'Enter new device name',
            autofocus: true,
          ),
          cancelText: 'CANCEL',
          confirmText: 'SAVE',
          onCancel: () => Navigator.pop(context),
          onConfirm: () async {
            final newName = controller.text.trim();
            if (newName.isNotEmpty) {
              Navigator.pop(context);
              await _setDeviceName(newName);
            }
          },
        );
      },
    );
  }

  Future<void> _setDeviceName(String newName) async {
    final client = Provider.of<JsonRpcRiftClient>(context, listen: false);
    try {
      await client.setDisplayName(newName);
      await _fetchDeviceInfo(); // Refresh to get the new name
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'Failed to update device name: ${JsonRpcRiftClient.formatDisplayError(e)}',
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _pickDefaultDownloadPath() async {
    try {
      final selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(AppPrefs.defaultDownloadPath, selectedDirectory);
        if (mounted) {
          setState(() {
            _defaultDownloadPath = selectedDirectory;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: 'Failed to pick directory: $e',
          type: RiftSnackbarType.error,
        );
      }
    }
  }

  void _showManualPairDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return PremiumDialog(
          title: 'Pair by IP',
          subtitle: 'Enter the IPv4 address and port of the peer device.',
          content: PremiumTextField(
            controller: controller,
            label: 'IP Address:Port',
            hint: 'e.g. 192.168.1.5:9140',
            autofocus: true,
          ),
          cancelText: 'CANCEL',
          confirmText: 'PAIR',
          onCancel: () => Navigator.pop(context),
          onConfirm: () {
            final input = controller.text.trim();
            if (input.isEmpty) return;
            
            final parts = input.split(':');
            if (parts.length != 2) {
              RiftSnackbar.show(
                context: context,
                message: 'Invalid format. Use IP:PORT',
                type: RiftSnackbarType.error,
              );
              return;
            }
            
            final address = parts[0];
            final port = int.tryParse(parts[1]);
            if (port == null) {
              RiftSnackbar.show(
                context: context,
                message: 'Invalid port number.',
                type: RiftSnackbarType.error,
              );
              return;
            }
            
            Navigator.pop(context);
            _performManualPair(address, port);
          },
        );

      },
    );
  }

  Future<void> _performManualPair(String address, int port) async {
    final client = Provider.of<JsonRpcRiftClient>(context, listen: false);
    try {
      final result = await client.startPairingByEndpoint(address, port);
      if (!mounted) return;
      
      final confirm = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            title: const Text('Confirm Pairing'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Device ID: ${result['deviceId']}'),
                const SizedBox(height: 8),
                const Text('Does this fingerprint match the other device?'),
                const SizedBox(height: 8),
                Text(
                  '${result['peerFingerprint']}',
                  style: const TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('REJECT'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('MATCH'),
              ),
            ],
          );
        },
      );

      if (confirm == true) {
        await client.approvePairing(
          result['deviceId'] as String,
          result['peerFingerprint'] as String,
        );
        if (!mounted) return;
        RiftSnackbar.show(
          context: context,
          message: 'Pairing successful!',
          type: RiftSnackbarType.success,
        );
      } else {
        await client.rejectPairing(result['deviceId'] as String);
      }
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'Manual pairing failed: ${JsonRpcRiftClient.formatDisplayError(e)}',
        type: RiftSnackbarType.error,
      );
    }
  }
}
