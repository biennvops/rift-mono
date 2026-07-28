import 'package:flutter/material.dart';

enum RiftSnackbarType {
  info,
  success,
  warning,
  error,
}

class RiftSnackbar {
  static const Color _successColor = Color(0xFF059669);
  static const Color _warningColor = Color(0xFFD97706);

  static void show({
    required BuildContext context,
    required String message,
    RiftSnackbarType type = RiftSnackbarType.info,
    Duration duration = const Duration(seconds: 4),
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    showWithState(
      messenger: messenger,
      message: message,
      type: type,
      duration: duration,
    );
  }

  static void showWithState({
    required ScaffoldMessengerState messenger,
    required String message,
    RiftSnackbarType type = RiftSnackbarType.info,
    Duration duration = const Duration(seconds: 4),
  }) {
    final theme = Theme.of(messenger.context);
    final colorScheme = theme.colorScheme;

    Color backgroundColor;
    IconData iconData;

    switch (type) {
      case RiftSnackbarType.success:
        backgroundColor = _successColor;
        iconData = Icons.check_circle_outline;
        break;
      case RiftSnackbarType.error:
        backgroundColor = colorScheme.error;
        iconData = Icons.gpp_bad_outlined;
        break;
      case RiftSnackbarType.warning:
        backgroundColor = _warningColor;
        iconData = Icons.warning_amber_rounded;
        break;
      case RiftSnackbarType.info:
        backgroundColor = colorScheme.primary;
        iconData = Icons.info_outline;
        break;
    }

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            messenger.hideCurrentSnackBar();
          },
          child: Row(
            children: [
              Icon(iconData, color: colorScheme.onPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        elevation: 0,
        margin: const EdgeInsets.all(16),
        duration: duration,
      ),
    );
  }
}
