import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

import '../constants.dart';
import 'blocked_peers_screen.dart';
import 'clipboard_debug_screen.dart';
import 'event_log_screen.dart';
import 'notifications_and_media_screen.dart';
import 'onboarding_screen.dart';
import 'pairing_screen.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/notification_sync_policy.dart';
import '../src/platform/android_shell.dart';
import '../src/platform/linux_notifications.dart';
import '../src/platform/macos_notifications.dart';
import '../src/platform/notification_route.dart';
import '../src/ui/theme.dart';
import '../src/platform/windows_shell.dart';
import '../widgets/rift_snackbar.dart';
import '../widgets/premium_dialog.dart';

// ── Design system semantic colors ──────────────────────────────────
const _kSuccessColor = Color(0xFF047857);
const _kSuccessBgColor = Color(0x14047857);
const _kTertiaryContainerColor = Color(0xFF3636C5);
const _kTertiaryContainerBgColor = Color(0x143636C5);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _activeTab = '';
  static const Duration _notificationPolicyDebounce =
      Duration(milliseconds: 300);
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
      message:
          'Unable to open notification settings on ${Platform.operatingSystem}.',
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
      message:
          'Notifications were not enabled. You can allow them in System Settings > Notifications.',
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
            ? 'Permission not requested'
            : 'Permission not granted';
      case 'unknown':
        return 'Status unavailable';
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
      return 'Android only';
    }

    switch (_notificationAccessStatus) {
      case 'authorized':
        return 'Enabled for sync';
      case 'denied':
        return 'Access is off';
      default:
        return 'Status unavailable';
    }
  }

  // ── Tab Rail ────────────────────────────────────────────────────

  Widget _buildTabRail(ThemeData theme) {
    final tabs = [
      ('general', 'General', Icons.tune),
      ('identity', 'Identity', Icons.badge_outlined),
      ('permissions', 'Permissions', Icons.security),
      ('system', 'System Checks', Icons.check_box_outlined),
      ('filetransfer', 'File Transfer', Icons.folder_shared_outlined),
      ('trust', 'Trust Store', Icons.shield_outlined),
      ('experimental', 'Experimental', Icons.science_outlined),
      ('about', 'About', Icons.info_outline),
    ];

    return Container(
      width: _sidebarWidth,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.all(8),
      child: ListView(
        children: tabs.map((tab) {
          final id = tab.$1;
          final label = tab.$2;
          final icon = tab.$3;
          final isActive = _activeTab == id;

          // body-md: 16px / 400 / 24px line-height
          final labelStyle = TextStyle(
            fontSize: 16,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            color: isActive
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.onSurfaceVariant,
            height: 24 / 16,
          );

          final itemContent = Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 18,
                color: isActive
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.85),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: labelStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );

          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Material(
              color: isActive ? theme.colorScheme.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                onTap: () => setState(() => _activeTab = id),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  decoration: isActive
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.5)),
                        )
                      : null,
                  child: itemContent,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMobileMenu(ThemeData theme) {
    final tabs = [
      ('general', 'General', Icons.tune),
      ('identity', 'Identity', Icons.badge_outlined),
      ('permissions', 'Permissions', Icons.security),
      ('system', 'System Checks', Icons.check_box_outlined),
      ('filetransfer', 'File Transfer', Icons.folder_shared_outlined),
      ('trust', 'Trust Store', Icons.shield_outlined),
      ('experimental', 'Experimental', Icons.science_outlined),
      ('about', 'About', Icons.info_outline),
    ];

    return ListView.separated(
      itemCount: tabs.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
      itemBuilder: (context, index) {
        final tab = tabs[index];
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(tab.$3, size: 18, color: theme.colorScheme.primary),
          ),
          title: Text(
            tab.$2,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => setState(() => _activeTab = tab.$1),
        );
      },
    );
  }

  // ── Shared UI primitives ────────────────────────────────────────

  Widget _buildBadge(
      ThemeData theme, String text, Color bgColor, Color textColor) {
    // label-sm: 12px / 500 / 16px line-height
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 16 / 12,
          color: Color(0xFF3636C5), // fallback, overridden by textColor param
        ),
      ),
    );
  }

  Widget _buildAndroidBadge(ThemeData theme) => _buildBadge(
      theme, 'Android', _kTertiaryContainerBgColor, _kTertiaryContainerColor);
  Widget _buildDesktopBadge(ThemeData theme) => _buildBadge(
      theme, 'Desktop', _kTertiaryContainerBgColor, _kTertiaryContainerColor);
  Widget _buildLinuxBadge(ThemeData theme) => _buildBadge(
      theme, 'Linux', _kTertiaryContainerBgColor, _kTertiaryContainerColor);
  Widget _buildGrantedChip(ThemeData theme) =>
      _buildBadge(theme, 'Granted', _kSuccessBgColor, _kSuccessColor);

  Widget _buildSuccessIcon(ThemeData theme) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: _kSuccessBgColor,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check, size: 15, color: _kSuccessColor),
    );
  }

  Widget _buildIconButton(
      ThemeData theme, IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        backgroundColor:
            theme.colorScheme.primaryContainer.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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

  Widget _buildSecondaryButton({
    required ThemeData theme,
    required VoidCallback onPressed,
    required String label,
    IconData? icon,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon != null ? Icon(icon, size: 16) : const SizedBox.shrink(),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: theme.colorScheme.primaryContainer,
        side: BorderSide(color: theme.colorScheme.primaryContainer),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    );
  }

  Widget _buildPrimaryButton({
    required ThemeData theme,
    required VoidCallback onPressed,
    required String label,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }

  // ── Panel structure ─────────────────────────────────────────────

  Widget _buildPanelHeader(ThemeData theme, String title, String desc,
      {Widget? badge}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.01,
                  height: 32 / 24,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 8),
              badge,
            ],
          ],
        ),
        const SizedBox(height: 4),
        // body-sm: 14px / 400 / 20px line-height
        Text(
          desc,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 20 / 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: RiftDesign.spaceLg),
      ],
    );
  }

  Widget _buildGroupLabel(ThemeData theme, String label, {Widget? badge}) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: RiftDesign.spaceSm, top: RiftDesign.spaceMd),
      child: Row(
        children: [
          // label-md: 14px / 600 / 0.05em / 16px line-height
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.05,
              height: 16 / 14,
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
    bool? trailingBelow,
    VoidCallback? onTap,
  }) {
    final titleWidget = Text(
      title,
      style: TextStyle(
        fontFamily: isMonoTitle ? 'JetBrains Mono' : null,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 24 / 16,
        color: theme.colorScheme.onSurface,
      ),
    );

    final subtitleWidget = Text(
      subtitle,
      style: TextStyle(
        fontFamily: isMonoSubtitle ? 'JetBrains Mono' : null,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 20 / 14,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    final putBelow = trailingBelow ?? (titleBadge != null);

    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (titleBadge != null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [titleWidget, titleBadge],
          )
        else
          titleWidget,
        const SizedBox(height: 2),
        subtitleWidget,
        if (putBelow && trailing != null) ...[
          const SizedBox(height: 8),
          trailing,
        ],
      ],
    );

    final content = Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color:
                    theme.colorScheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leadingIcon != null) ...[
            leadingIcon,
            const SizedBox(width: 16),
          ],
          Expanded(child: textColumn),
          if (!putBelow && trailing != null) ...[
            const SizedBox(width: 16),
            trailing,
          ],
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: content,
      );
    }
    return content;
  }

  // ── Panel: General ──────────────────────────────────────────────

  Widget _buildGeneralPanel(ThemeData theme, String displayName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'General', 'Device identity and pairing.'),
        _buildRow(
          theme: theme,
          title: 'Device name',
          subtitle: displayName,
        ),
        _buildRow(
          theme: theme,
          title: 'Pair by IP',
          subtitle: 'Connect using an IP address',
          trailing: _buildIconButton(
              theme, Icons.router, 'Pair by IP', _showManualPairDialog),
          onTap: _showManualPairDialog,
        ),
        _buildRow(
          theme: theme,
          title: 'Theme',
          subtitle: 'System default',
          trailing: Icon(Icons.lock_outline, color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  // ── Panel: Identity ────────────────────────────────────────────

  Widget _buildIdentityPanel(
      ThemeData theme, String deviceId, String fingerprint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(
            theme, 'Identity', 'Identity used to verify trusted devices.'),
        _buildRow(
          theme: theme,
          title: 'Device ID',
          subtitle: deviceId,
          isMonoSubtitle: true,
          trailing: _buildIconButton(
              theme,
              Icons.copy,
              'Copy Device ID',
              () =>
                  _copyToClipboard(deviceId, 'Device ID copied to clipboard')),
        ),
        _buildRow(
          theme: theme,
          title: 'Fingerprint',
          subtitle: fingerprint,
          isMonoSubtitle: true,
          trailing: _buildIconButton(
              theme,
              Icons.copy,
              'Copy Fingerprint',
              () => _copyToClipboard(
                  fingerprint, 'Fingerprint copied to clipboard')),
        ),
      ],
    );
  }

  // ── Panel: Permissions ─────────────────────────────────────────

  Widget _buildPermissionsPanel(ThemeData theme, String localNetworkSubtitle,
      String backgroundExecSubtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'Permissions & System Sync',
            'Permissions and cross-device sync.'),
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
          leadingIcon: Icon(_notificationPermissionIcon,
              color: _notificationPermissionColor(theme), size: 20),
          trailingBelow: !_notificationsAuthorized,
          trailing: _notificationsAuthorized
              ? _buildGrantedChip(theme)
              : (_canManageNotificationSettings
                  ? _buildPrimaryButton(
                      theme: theme,
                      onPressed: _handleNotificationPermissionAction,
                      label: _notificationPermissionActionLabel,
                    )
                  : null),
        ),
        if (AndroidShell.isSupported)
          _buildRow(
            theme: theme,
            title: 'Notification access',
            subtitle: _notificationAccessSubtitle,
            titleBadge: _buildAndroidBadge(theme),
            leadingIcon: Icon(_notificationAccessIcon,
                color: _notificationAccessColor(theme), size: 20),
            trailing: _notificationAccessAuthorized
                ? _buildGrantedChip(theme)
                : _buildPrimaryButton(
                    theme: theme,
                    onPressed: _openNotificationAccessSettings,
                    label: 'OPEN SETTINGS',
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
          title: 'Notifications & Media',
          subtitle: 'Notifications and media from trusted devices',
          leadingIcon: Icon(
            Icons.sync_alt,
            color: theme.colorScheme.primary,
            size: 20,
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: theme.colorScheme.outline,
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const NotificationsAndMediaScreen(),
              ),
            );
          },
        ),
        _buildRow(
          theme: theme,
          title: 'Clipboard received notifications',
          subtitle: 'Notify when clipboard content arrives',
          trailing: Switch(
            value: _clipboardNotificationsEnabled,
            onChanged: _setClipboardNotificationsEnabled,
          ),
        ),
        _buildRow(
          theme: theme,
          title: 'Android notification sync',
          subtitle: _notificationAccessAuthorized
              ? 'Mirror to trusted desktop devices'
              : 'Enable Android notification access to sync',
          titleBadge: _buildAndroidBadge(theme),
          trailingBelow: false,
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
            border: Border(
                bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.4))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Notification blacklist',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 24 / 16,
                    color: theme.colorScheme.onSurface,
                  )),
              const SizedBox(height: 2),
              Text('One package per line. Blocked apps stay local.',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    height: 20 / 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 8),
              TextField(
                controller: _notificationBlacklistController,
                minLines: 2,
                maxLines: 4,
                // Giữ mono cho dữ liệu kỹ thuật (package names)
                style:
                    const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 14),
                onChanged: (_) => _scheduleNotificationSyncPolicyPersist(),
                decoration: InputDecoration(
                  filled: false,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide:
                          BorderSide(color: theme.colorScheme.outlineVariant)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.6))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(
                          color: theme.colorScheme.primaryContainer, width: 2)),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ],
          ),
        ),
        if (AndroidShell.isSupported)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: _buildSecondaryButton(
              theme: theme,
              onPressed: _showTestNotification,
              label: 'Test notification',
              icon: Icons.notifications_active_outlined,
            ),
          ),
      ],
    );
  }

  // ── Panel: System Checks ───────────────────────────────────────

  Widget _buildSystemPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(
          theme,
          'System Checks',
          'Requirements for discovery and sync.',
          badge: Platform.isLinux
              ? _buildLinuxBadge(theme)
              : (Platform.isAndroid
                  ? _buildAndroidBadge(theme)
                  : _buildDesktopBadge(theme)),
        ),
        if (Platform.isLinux) ...[
          _buildRow(
              theme: theme,
              title: 'avahi-daemon',
              subtitle: 'running',
              leadingIcon: _buildSuccessIcon(theme),
              isMonoTitle: true,
              isMonoSubtitle: true),
          _buildRow(
              theme: theme,
              title: 'appindicator',
              subtitle: 'supported',
              leadingIcon: _buildSuccessIcon(theme),
              isMonoTitle: true,
              isMonoSubtitle: true),
        ] else if (Platform.isAndroid) ...[
          _buildRow(
              theme: theme,
              title: 'Android Clipboard Monitoring',
              subtitle: 'Native clipboard and foreground service',
              leadingIcon: _buildSuccessIcon(theme)),
        ] else ...[
          _buildRow(
              theme: theme,
              title: 'Platform check',
              subtitle:
                  'No platform-specific checks for ${Platform.operatingSystem} yet.'),
        ],
        if (Platform.isAndroid) ...[
          _buildGroupLabel(theme, 'CLIPBOARD',
              badge: _buildAndroidBadge(theme)),
          _buildRow(
              theme: theme,
              title: 'Background clipboard monitoring',
              subtitle:
                  'Uses Rift foreground service when background sync is active'),
        ],
      ],
    );
  }

  // ── Panel: File Transfer ───────────────────────────────────────

  Widget _buildFileTransferPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(
            theme, 'File Transfer', 'Where received files are saved.'),
        _buildRow(
          theme: theme,
          title: 'Default Download Location',
          subtitle: _defaultDownloadPath ?? 'Downloads/Rift (System Default)',
          isMonoSubtitle: true,
          trailing: _buildIconButton(theme, Icons.folder_open, 'Choose folder',
              _pickDefaultDownloadPath),
          onTap: _pickDefaultDownloadPath,
        ),
      ],
    );
  }

  // ── Panel: Trust Store ─────────────────────────────────────────

  Widget _buildTrustPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'Trust Store', 'Manage trusted device keys.'),
        _buildSecondaryButton(
          theme: theme,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BlockedPeersScreen()),
            );
          },
          label: 'MANAGE TRUST STORE',
          icon: Icons.folder_outlined,
        ),
      ],
    );
  }

  // ── Panel: Experimental ────────────────────────────────────────

  Widget _buildExperimentalPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(
          theme,
          'Experimental',
          'Features and diagnostic tools in testing.',
        ),
        if (_isDesktopPlatform)
          _buildRow(
            theme: theme,
            title: 'Test desktop sync',
            subtitle: 'Send a desktop test notification',
            trailing: _buildSecondaryButton(
              theme: theme,
              onPressed: _showDesktopTestNotification,
              label: 'TEST',
              icon: Icons.desktop_windows_outlined,
            ),
            onTap: _showDesktopTestNotification,
          ),
        _buildRow(
          theme: theme,
          title: 'Restart onboarding',
          subtitle: 'Reopen setup as if the app was just installed',
          trailing: _buildSecondaryButton(
            theme: theme,
            onPressed: _restartOnboarding,
            label: 'RESTART',
            icon: Icons.refresh_outlined,
          ),
          onTap: _restartOnboarding,
        ),
      ],
    );
  }

  Future<void> _restartOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_completed_onboarding', false);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const OnboardingScreen()),
      (route) => false,
    );
  }

  // ── Panel: About ───────────────────────────────────────────────

  Widget _buildAboutPanel(
      ThemeData theme, String implementationId, String protocolVersion) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader(theme, 'About Application', 'Version and audit.'),
        _buildRow(
            theme: theme, title: 'Implementation', subtitle: implementationId),
        _buildRow(
            theme: theme,
            title: 'Protocol version',
            subtitle: protocolVersion,
            isMonoSubtitle: true),
        _buildRow(
          theme: theme,
          title: 'Event log',
          subtitle: 'Open local audit trail',
          trailing: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const EventLogScreen(),
              ),
            );
          },
        ),
        if (kDebugMode)
          _buildRow(
            theme: theme,
            title: 'Clipboard diagnostics',
            subtitle: 'Inspect clipboard state',
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ClipboardDebugScreen(),
                ),
              );
            },
          ),
      ],
    );
  }

  // ── Active panel with white card container ─────────────────────

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
        content = _buildPermissionsPanel(
            theme, localNetworkSubtitle, backgroundExecSubtitle);
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
      case 'experimental':
        content = _buildExperimentalPanel(theme);
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
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            const SizedBox(height: 16),
          ],
          // White card: bg + 1px border + no shadow, rounded-lg (8px)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            padding:
                const EdgeInsets.only(left: 24, right: 24, top: 20, bottom: 16),
            child: content,
          ),
        ],
      ),
    );
  }

  // ── Main build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
            automaticallyImplyLeading: widget.onClose == null,
            titleSpacing: widget.onClose != null ? 16 : null,
            title: Text(
              'Settings',
              // headline-md: 24px / 600 / -0.01em
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.01,
                height: 32 / 24,
                color: theme.colorScheme.onSurface,
              ),
            ),
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
        ? 'Used for discovery and pairing'
        : 'Managed by the local daemon';
    final backgroundExecSubtitle = Platform.isAndroid
        ? 'Uses a foreground service'
        : 'Managed by the local daemon';

    final isMobile = MediaQuery.of(context).size.width < 720;

    if (isMobile) {
      final showingDetail = _activeTab.isNotEmpty;
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          backgroundColor: theme.colorScheme.surface,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleSpacing: showingDetail || widget.onClose != null ? 0 : 16,
          leading: showingDetail
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _activeTab = ''),
                )
              : widget.onClose != null
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: widget.onClose,
                    )
                  : null,
          automaticallyImplyLeading: !showingDetail && widget.onClose == null,
          iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
          title: Text(
            showingDetail ? _activePanelTitle(_activeTab) : 'Settings',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          ),
        ),
        body: showingDetail
            ? _buildActivePanel(
                theme,
                displayName,
                deviceId,
                fingerprint,
                implementationId,
                protocolVersion,
                localNetworkSubtitle,
                backgroundExecSubtitle,
              )
            : _buildMobileMenu(theme),
      );
    }

    final isEmbeddedInShell = widget.onClose == null;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: isEmbeddedInShell
          ? null
          : AppBar(
              backgroundColor: theme.colorScheme.surface,
              elevation: 0,
              scrolledUnderElevation: 0,
              automaticallyImplyLeading: true,
              iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
              title: Text(
                'Settings',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                  letterSpacing: -0.5,
                ),
              ),
              actions: [
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Close Settings',
                ),
                const SizedBox(width: 8),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5)),
              ),
            ),
      body: Padding(
        padding:
            isEmbeddedInShell ? RiftDesign.padScreenDesktop : EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isEmbeddedInShell) ...[
              Text(
                'Settings',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: RiftDesign.spaceMd),
            ],
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTabRail(theme),
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanUpdate: (details) {
                        setState(() {
                          _sidebarWidth = (_sidebarWidth + details.delta.dx)
                              .clamp(160.0, 400.0);
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
            ),
          ],
        ),
      ),
    );
  }

  // ── Dialogs ────────────────────────────────────────────────────

  String _activePanelTitle(String tab) {
    switch (tab) {
      case 'general':
        return 'General';
      case 'identity':
        return 'Identity';
      case 'permissions':
        return 'Permissions';
      case 'system':
        return 'System Checks';
      case 'filetransfer':
        return 'File Transfer';
      case 'trust':
        return 'Trust Store';
      case 'experimental':
        return 'Experimental';
      case 'about':
        return 'About';
      default:
        return 'Settings';
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
            if (port == null || port < 1 || port > 65535) {
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
    final client = context.read<JsonRpcRiftClient>();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (_) => Provider<JsonRpcRiftClient>.value(
        value: client,
        child: PairingScreen.forEndpoint(
          address: address,
          port: port,
          displayName: '$address:$port',
        ),
      ),
    );
  }
}
