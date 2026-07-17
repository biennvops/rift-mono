import 'package:flutter/material.dart';

enum RiftSnackbarType {
  info,
  success,
  warning,
  error,
}

class RiftSnackbar {
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
    Color backgroundColor;
    Color iconColor = Colors.white;
    IconData iconData;

    switch (type) {
      case RiftSnackbarType.success:
        backgroundColor = const Color(0xFF006E06); // Trusted Green
        iconData = Icons.check_circle_outline;
        break;
      case RiftSnackbarType.error:
        backgroundColor = const Color(0xFFBA1A1A); // Revoked Red
        iconData = Icons.gpp_bad_outlined;
        break;
      case RiftSnackbarType.warning:
        backgroundColor = Colors.amber.shade800; // Pending Amber
        iconData = Icons.warning_amber_rounded;
        break;
      case RiftSnackbarType.info:
        backgroundColor = const Color(0xFF00328A); // Trust Blue
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
              Icon(iconData, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        elevation: 4, // Level 2 elevation
        margin: const EdgeInsets.all(16),
        duration: duration,
      ),
    );
  }
}
