import 'package:flutter/material.dart';

@immutable
class OrbitPeerLayoutState {
  const OrbitPeerLayoutState({
    required this.deviceId,
    required this.from,
    required this.to,
    required this.entering,
    required this.leaving,
    this.preservePresence = false,
  });

  final String deviceId;
  final Offset from;
  final Offset to;
  final bool entering;
  final bool leaving;
  final bool preservePresence;

  Offset centerAt(double progress) => Offset.lerp(from, to, progress)!;
}
