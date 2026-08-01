import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../src/platform/ios_notifications.dart';

class BackgroundSyncScreen extends StatelessWidget {
  final Future<void> Function(BuildContext context)? onFinish;

  const BackgroundSyncScreen({
    super.key,
    this.onFinish,
  });

  Future<void> _finishOnboarding(BuildContext context) async {
    if (onFinish != null) {
      await onFinish!(context);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_completed_onboarding', true);

    if (!context.mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AppShell()),
    );
  }

  List<({IconData icon, Color roleColor, String title, String body})>
      _buildChecklist(ThemeData theme) {
    if (Platform.isAndroid) {
      return [
        (
          icon: Icons.check_circle,
          roleColor: theme.colorScheme.secondary,
          title: 'Clipboard sync stays inside platform clipboard APIs',
          body:
              'Rift uses the Android clipboard APIs and its foreground-service flow. It does not require Accessibility Service.',
        ),
        (
          icon: Icons.info,
          roleColor: theme.colorScheme.primary,
          title: 'Background work can still vary by device vendor',
          body:
              'Some Android skins may pause background work aggressively. If sync feels delayed later, you can revisit device battery settings.',
        ),
        (
          icon: Icons.check_circle,
          roleColor: theme.colorScheme.secondary,
          title: 'No extra setup is required to finish now',
          body:
              'You can complete onboarding immediately and adjust background behavior later only if your device needs it.',
        ),
      ];
    }

    if (IOSNotifications.isSupported) {
      return [
        (
          icon: Icons.info,
          roleColor: theme.colorScheme.primary,
          title: 'iOS decides how long Rift runs in the background',
          body:
              'Normal iOS builds do not provide a continuously running daemon. Keep Rift open for the most reliable discovery and transfers.',
        ),
        (
          icon: Icons.location_on,
          roleColor: theme.colorScheme.tertiary,
          title: 'Development builds can improve background continuity',
          body:
              'A sideload build may opt into location-backed keepalive. It requires location permission and shows the normal iOS location indicator.',
        ),
        (
          icon: Icons.content_paste,
          roleColor: theme.colorScheme.secondary,
          title: 'Clipboard changes remain explicit',
          body:
              'Open Rift and use Send Clipboard, Copy, or Copy Image. iOS does not allow Rift to silently replace the clipboard while suspended.',
        ),
      ];
    }

    return [
      (
        icon: Icons.check_circle,
        roleColor: theme.colorScheme.secondary,
        title: 'Desktop sync runs through the local daemon',
        body:
            'Rift keeps discovery, trust, clipboard, and file flows available through the desktop session and local daemon.',
      ),
      (
        icon: Icons.check_circle,
        roleColor: theme.colorScheme.secondary,
        title: 'No mobile-style background exemption is required here',
        body:
            'Desktop targets do not need battery-optimization screens for normal local syncing.',
      ),
      (
        icon: Icons.info,
        roleColor: theme.colorScheme.primary,
        title: 'You can review permissions later in Settings',
        body:
            'Notification status and platform-specific checks remain available in the app settings screen after setup.',
      ),
    ];
  }

  String _headline() {
    if (Platform.isAndroid || IOSNotifications.isSupported) {
      return 'Background Sync Review';
    }
    return 'Setup Review';
  }

  String _intro() {
    if (Platform.isAndroid) {
      return 'Rift is ready to run with its daemon and foreground-service flow. This screen is just a final check so the user knows what is and is not being requested.';
    }
    if (IOSNotifications.isSupported) {
      return 'Rift is ready to finish setup on iOS. This review explains the platform limits and the optional development keepalive behavior.';
    }
    return 'Rift is ready to finish setup on this desktop target. This last step summarizes what will keep running after onboarding ends.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checklist = _buildChecklist(theme);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        title: Row(
          children: [
            Icon(Icons.sync, color: theme.colorScheme.primary),
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
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                children: [
                  Text(
                    _headline(),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _intro(),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      border:
                          Border.all(color: theme.colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.verified_user,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'What this step means',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Rift does not need a special in-app approval here. Finishing setup records that onboarding is complete and takes you into the main app.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  ...checklist.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ChecklistCard(
                        icon: item.icon,
                        roleColor: item.roleColor,
                        title: item.title,
                        body: item.body,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border:
                          Border.all(color: theme.colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lock_outline,
                            color: theme.colorScheme.outline),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Accessibility remains out of scope',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Rift is not asking for full-device observation or accessibility-style scraping for clipboard sync.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.onSurface,
                          side: BorderSide(color: theme.colorScheme.outline),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: () => _finishOnboarding(context),
                        child: const Text(
                          'Finish Later',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: () => _finishOnboarding(context),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text(
                          'Finish Setup',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChecklistCard extends StatelessWidget {
  final IconData icon;
  final Color roleColor;
  final String title;
  final String body;

  const _ChecklistCard({
    required this.icon,
    required this.roleColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: roleColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
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
