import 'dart:math' as math;

import 'package:flutter/material.dart';

enum DeviceFocusNodeKind {
  power,
  security,
  identity,
  capabilities,
  info,
}

@immutable
class DeviceFocusGeometry {
  const DeviceFocusGeometry({
    required this.center,
    required this.coreSize,
    required this.nodeSize,
    required this.nodeCenters,
  });

  final Offset center;
  final double coreSize;
  final Size nodeSize;
  final Map<DeviceFocusNodeKind, Offset> nodeCenters;
}

abstract final class DeviceFocusLayout {
  static DeviceFocusGeometry calculate(
    Size size,
    Iterable<DeviceFocusNodeKind> kinds,
  ) {
    final activeKinds = kinds.toList(growable: false);
    final slots = _slotsFor(activeKinds);
    final nodeWidth = (size.width * 0.18).clamp(96.0, 120.0).toDouble();
    final nodeHeight = (size.height * 0.1).clamp(76.0, 84.0).toDouble();
    final nodeSize = Size(nodeWidth, nodeHeight);

    final maxHorizontalRadius = math
        .max(
          64.0,
          (size.width - nodeWidth) / 2 - 18,
        )
        .toDouble();
    final radiusX = math
        .min(
          280.0,
          math.min(size.width * 0.34, maxHorizontalRadius),
        )
        .toDouble();

    final topNodeCenter = 72 + nodeHeight / 2;
    final bottomNodeCenter = size.height - 20 - nodeHeight / 2;
    final verticalSpan = math.max(120.0, bottomNodeCenter - topNodeCenter);
    final normalizedYs =
        slots.values.map((slot) => slot.dy).toList(growable: false);
    final minY = normalizedYs.isEmpty ? 0.0 : normalizedYs.reduce(math.min);
    final maxY = normalizedYs.isEmpty ? 0.0 : normalizedYs.reduce(math.max);
    final normalizedSpan = math.max(1.0, maxY - minY);
    final radiusY = math
        .min(
          math.min(220.0, size.height * 0.28),
          verticalSpan / normalizedSpan,
        )
        .toDouble();

    final minimumCenterY = topNodeCenter - minY * radiusY;
    final maximumCenterY = bottomNodeCenter - maxY * radiusY;
    final preferredCenterY = size.height * 0.45;
    final centerY = minimumCenterY <= maximumCenterY
        ? preferredCenterY.clamp(minimumCenterY, maximumCenterY).toDouble()
        : size.height / 2;
    final center = Offset(size.width / 2, centerY);

    final nodeCenters = <DeviceFocusNodeKind, Offset>{
      for (final kind in activeKinds)
        kind: center +
            Offset(
              slots[kind]!.dx * radiusX,
              slots[kind]!.dy * radiusY,
            ),
    };

    final coreSize = math
        .min(size.width * 0.31, size.height * 0.24)
        .clamp(140.0, 180.0)
        .toDouble();

    return DeviceFocusGeometry(
      center: center,
      coreSize: coreSize,
      nodeSize: nodeSize,
      nodeCenters: nodeCenters,
    );
  }

  static Map<DeviceFocusNodeKind, Offset> _slotsFor(
    List<DeviceFocusNodeKind> kinds,
  ) {
    if (kinds.length == 5) {
      return const {
        DeviceFocusNodeKind.power: Offset(0, -1),
        DeviceFocusNodeKind.security: Offset(-1, -0.08),
        DeviceFocusNodeKind.identity: Offset(1, -0.08),
        DeviceFocusNodeKind.capabilities: Offset(-0.7, 0.72),
        DeviceFocusNodeKind.info: Offset(0.7, 0.72),
      };
    }

    final normalizedSlots = switch (kinds.length) {
      1 => const [Offset(0, -1)],
      2 => const [Offset(-1, 0), Offset(1, 0)],
      3 => const [Offset(0, -1), Offset(-0.8, 0.7), Offset(0.8, 0.7)],
      4 => const [
          Offset(0, -1),
          Offset(1, 0),
          Offset(0, 1),
          Offset(-1, 0),
        ],
      _ => const <Offset>[],
    };
    return {
      for (var index = 0; index < kinds.length; index++)
        kinds[index]: normalizedSlots[index],
    };
  }
}
