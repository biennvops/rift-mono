import 'package:flutter/material.dart';

abstract final class RiftMotion {
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 500);
  static const Duration scene = Duration(milliseconds: 800);

  static bool reducedMotionOf(BuildContext context) {
    return MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  }

  static Duration durationOf(BuildContext context, Duration duration) {
    return reducedMotionOf(context) ? Duration.zero : duration;
  }
}
