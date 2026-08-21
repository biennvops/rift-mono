import 'package:flutter/material.dart';

import 'orbit_peer_presentation.dart';

class DevicePlaybackStatusGlyph extends StatelessWidget {
  const DevicePlaybackStatusGlyph({
    super.key,
    required this.activity,
    required this.color,
    this.size = 13,
  });

  final OrbitPeerActivity activity;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: switch (activity) {
        OrbitPeerActivity.mediaPlaying => Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StatusBar(height: size * 0.46, color: color),
              _StatusBar(height: size * 0.85, color: color),
              _StatusBar(height: size * 0.62, color: color),
            ],
          ),
        OrbitPeerActivity.mediaPaused => Icon(
            Icons.pause,
            size: size,
            color: color,
          ),
        OrbitPeerActivity.mediaBuffering => Icon(
            Icons.sync,
            size: size * 0.92,
            color: color,
          ),
        OrbitPeerActivity.none => const SizedBox.shrink(),
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 2,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}
