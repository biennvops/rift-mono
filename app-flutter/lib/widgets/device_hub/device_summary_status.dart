import 'package:flutter/material.dart';

import 'device_playback_status_glyph.dart';
import 'orbit_peer_presentation.dart';

class DeviceSummaryStatus extends StatelessWidget {
  const DeviceSummaryStatus({
    super.key,
    required this.presentation,
    required this.accentColor,
    this.mutedColor,
    this.alignment = WrapAlignment.start,
    this.showStatus = true,
  });

  final OrbitPeerPresentation presentation;
  final Color accentColor;
  final Color? mutedColor;
  final WrapAlignment alignment;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final neutralColor = mutedColor ?? theme.colorScheme.onSurfaceVariant;
    final liveColor = presentation.isOnline ? accentColor : neutralColor;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: neutralColor,
      fontWeight: FontWeight.w600,
    );
    final power = presentation.powerStatus;
    final mediaLabel = presentation.mediaStateLabel;

    return Wrap(
      alignment: alignment,
      spacing: 10,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showStatus)
          _SummaryItem(
            icon: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: liveColor,
                shape: BoxShape.circle,
              ),
            ),
            label: presentation.statusSummaryLabel,
            style: style?.copyWith(color: liveColor),
          ),
        if (power != null)
          _SummaryItem(
            icon: Icon(
              power.isCharging
                  ? Icons.battery_charging_full
                  : Icons.battery_std,
              size: 14,
              color: liveColor,
            ),
            label: presentation.powerLabel!,
            style: style?.copyWith(color: liveColor),
          ),
        if (mediaLabel != null)
          _SummaryItem(
            icon: DevicePlaybackStatusGlyph(
              key: ValueKey(
                'device-summary-media-${presentation.activity.name}-${presentation.deviceId}',
              ),
              activity: presentation.activity,
              color: liveColor,
              size: 13,
            ),
            label: mediaLabel,
            style: style?.copyWith(color: liveColor),
          ),
      ],
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.icon,
    required this.label,
    required this.style,
  });

  final Widget icon;
  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}
