import 'package:flutter/foundation.dart';

@immutable
class DeviceOrbitMotionState {
  const DeviceOrbitMotionState({
    required this.reducedMotion,
    required this.hasFocusedPeer,
    required this.hasKeyboardFocus,
    required this.interactingPeerCount,
  });

  final bool reducedMotion;
  final bool hasFocusedPeer;
  final bool hasKeyboardFocus;
  final int interactingPeerCount;

  bool get isPaused =>
      reducedMotion ||
      hasFocusedPeer ||
      hasKeyboardFocus ||
      interactingPeerCount > 0;
}
