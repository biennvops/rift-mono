import 'package:flutter/foundation.dart';

@immutable
class DeviceOrbitMotionState {
  const DeviceOrbitMotionState({
    required this.reducedMotion,
    required this.hasFocusedPeer,
    required this.hasKeyboardFocus,
    required this.interactingPeerCount,
    this.membershipTransitioning = false,
  });

  final bool reducedMotion;
  final bool hasFocusedPeer;
  final bool hasKeyboardFocus;
  final int interactingPeerCount;
  final bool membershipTransitioning;

  bool get isPaused =>
      reducedMotion ||
      hasFocusedPeer ||
      hasKeyboardFocus ||
      membershipTransitioning ||
      interactingPeerCount > 0;
}
