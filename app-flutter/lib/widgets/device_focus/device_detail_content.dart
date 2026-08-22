import 'package:flutter/material.dart';

import '../../src/media_playback/playback_presentation.dart';
import '../../src/ui/motion.dart';

@immutable
class DeviceDetailRow {
  const DeviceDetailRow({required this.label, required this.value});

  final String label;
  final String value;
}

@immutable
class DevicePowerDetails {
  const DevicePowerDetails({
    required this.rows,
    required this.isStale,
    required this.hasBattery,
  });

  factory DevicePowerDetails.fromStatus(
    Map<String, dynamic> status, {
    required bool isOnline,
  }) {
    final isStale = status['isStale'] == true || !isOnline;
    final rows = <DeviceDetailRow>[];
    final batteryPresent = status['batteryPresent'];
    final batteryPercent = status['batteryPercent'];
    if (batteryPresent == false) {
      rows.add(const DeviceDetailRow(label: 'Battery', value: 'No battery'));
    } else if (batteryPercent is num) {
      rows.add(
        DeviceDetailRow(
          label: 'Battery',
          value: '${batteryPercent.toInt()}%',
        ),
      );
    }

    final chargingState = status['chargingState']?.toString();
    if (chargingState != null) {
      rows.add(
        DeviceDetailRow(
          label: 'Charging state',
          value: formatDeviceChargingState(chargingState),
        ),
      );
    }

    final powerSource = status['powerSource']?.toString();
    if (powerSource != null) {
      rows.add(
        DeviceDetailRow(
          label: 'Power source',
          value: formatDevicePowerSource(powerSource),
        ),
      );
    }

    if (status['lowPowerMode'] is bool) {
      rows.add(
        DeviceDetailRow(
          label: 'Low Power Mode',
          value: status['lowPowerMode'] == true ? 'On' : 'Off',
        ),
      );
    }

    final observedAt = formatDeviceTimestamp(status['observedAt']?.toString());
    rows.add(
      DeviceDetailRow(
        label: 'Status',
        value: isStale ? 'Stale · $observedAt' : observedAt,
      ),
    );

    return DevicePowerDetails(
      rows: rows,
      isStale: isStale,
      hasBattery: batteryPresent != false,
    );
  }

  final List<DeviceDetailRow> rows;
  final bool isStale;
  final bool hasBattery;

  String summary(String? livePowerLabel) {
    if (livePowerLabel != null) return livePowerLabel;
    if (isStale) return 'Status stale';
    if (!hasBattery) return 'No battery';
    return 'Status';
  }
}

List<String> deviceCapabilityNames(Object? value) {
  if (value is! List) return const [];

  final names = <String>[];
  for (final capability in value) {
    final name = _deviceCapabilityName(capability);
    if (name != null) names.add(name);
  }
  return names;
}

String? _deviceCapabilityName(Object? capability) {
  final value = capability is Map
      ? capability['name']?.toString().trim() ?? ''
      : capability?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

@immutable
class DeviceFeaturePresentation {
  const DeviceFeaturePresentation({
    required this.capability,
    required this.label,
    required this.icon,
  });

  factory DeviceFeaturePresentation.fromCapability(String capability) {
    return DeviceFeaturePresentation(
      capability: capability,
      label: switch (capability) {
        'clipboard.offer_fetch' => 'Clipboard sync',
        'device.status' => 'Device status',
        'file.transfer' => 'File transfer',
        'media.playback' => 'Media playback',
        'notification.sync' => 'Notification sync',
        'operation.lifecycle' => 'Operations',
        'presence.basic' => 'Presence',
        'security.event_log' => 'Security event log',
        _ => capability,
      },
      icon: switch (capability) {
        'clipboard.offer_fetch' => Icons.content_paste_outlined,
        'device.status' => Icons.monitor_heart_outlined,
        'file.transfer' => Icons.folder_outlined,
        'media.playback' => Icons.graphic_eq,
        'notification.sync' => Icons.notifications_outlined,
        'operation.lifecycle' => Icons.sync_alt,
        'presence.basic' => Icons.wifi_tethering,
        'security.event_log' => Icons.policy_outlined,
        _ => Icons.extension_outlined,
      },
    );
  }

  final String capability;
  final String label;
  final IconData icon;
}

class DeviceMediaDetailsView extends StatelessWidget {
  const DeviceMediaDetailsView({
    super.key,
    required this.media,
    this.accentColor,
  });

  final MediaPlaybackPresentation? media;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = accentColor ?? colors.primary;
    final hasPosition = media?.positionMs != null &&
        media?.durationMs != null &&
        media!.durationMs! > 0;
    final progress = hasPosition
        ? (media!.positionMs! / media!.durationMs!).clamp(0.0, 1.0)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MediaArtworkSlot(media: media),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    media?.displayTitle ?? 'Nothing playing',
                    key: const ValueKey('device-focus-media-title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (media != null && media!.artist.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      media!.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                  if (media != null && media!.album.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      media!.album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    media?.stateLabel ?? 'Nothing playing',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (hasPosition) ...[
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatPlaybackTime(media!.positionMs!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                _formatPlaybackTime(media!.durationMs!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            key: const ValueKey('device-focus-media-progress'),
            value: progress,
            color: accent,
            minHeight: 4,
            borderRadius: BorderRadius.circular(999),
          ),
        ],
        if (media != null && media!.application.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                Icons.apps_outlined,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  media!.application,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _MediaArtworkSlot extends StatelessWidget {
  const _MediaArtworkSlot({required this.media});

  final MediaPlaybackPresentation? media;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = media?.artworkBytes;
    final identity = media?.artworkIdentity;
    final artwork = bytes == null || identity == null
        ? Container(
            key: const ValueKey('device-focus-media-artwork-placeholder'),
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Icon(
              Icons.graphic_eq,
              size: 38,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        : ClipRRect(
            key: ValueKey('device-focus-media-artwork-$identity'),
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              width: 104,
              height: 104,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stackTrace) => Container(
                width: 104,
                height: 104,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.graphic_eq,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
    return SizedBox.square(
      dimension: 104,
      child: AnimatedSwitcher(
        duration: RiftMotion.durationOf(context, RiftMotion.normal),
        switchInCurve: RiftMotion.enter,
        switchOutCurve: RiftMotion.exit,
        child: artwork,
      ),
    );
  }
}

class DeviceFeaturesView extends StatelessWidget {
  const DeviceFeaturesView({
    super.key,
    required this.capabilities,
    this.onOpenClipboardActivity,
    this.onSendFile,
    this.onViewTransferActivity,
  });

  final List<String> capabilities;
  final VoidCallback? onOpenClipboardActivity;
  final VoidCallback? onSendFile;
  final VoidCallback? onViewTransferActivity;

  @override
  Widget build(BuildContext context) {
    if (capabilities.isEmpty) {
      return Text(
        'No negotiated features reported.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < capabilities.length; index++) ...[
          _FeatureRow(
            feature: DeviceFeaturePresentation.fromCapability(
              capabilities[index],
            ),
            onOpenClipboardActivity: onOpenClipboardActivity,
            onSendFile: onSendFile,
            onViewTransferActivity: onViewTransferActivity,
          ),
          if (index != capabilities.length - 1)
            Divider(
              height: 20,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
        ],
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.feature,
    this.onOpenClipboardActivity,
    this.onSendFile,
    this.onViewTransferActivity,
  });

  final DeviceFeaturePresentation feature;
  final VoidCallback? onOpenClipboardActivity;
  final VoidCallback? onSendFile;
  final VoidCallback? onViewTransferActivity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = _actions();
    return Container(
      key: ValueKey('device-focus-feature-${feature.capability}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                feature.icon,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  feature.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                'Available',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }

  List<Widget> _actions() => switch (feature.capability) {
        'clipboard.offer_fetch' => [
            if (onOpenClipboardActivity != null)
              FilledButton.icon(
                key: const ValueKey('device-focus-open-clipboard'),
                onPressed: onOpenClipboardActivity,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open Clipboard'),
              ),
          ],
        'file.transfer' => [
            if (onSendFile != null)
              FilledButton.icon(
                key: const ValueKey('device-focus-send-file'),
                onPressed: onSendFile,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Send File'),
              ),
            if (onViewTransferActivity != null)
              OutlinedButton.icon(
                key: const ValueKey('device-focus-view-transfers'),
                onPressed: onViewTransferActivity,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Transfers'),
              ),
          ],
        _ => const [],
      };
}

String formatDeviceChargingState(String value) => switch (value) {
      'charging' => 'Charging',
      'discharging' => 'Discharging',
      'full' => 'Full',
      'notCharging' => 'Not charging',
      _ => 'Unknown',
    };

String formatDevicePowerSource(String value) => switch (value) {
      'ac' => 'AC power',
      'usb' => 'USB power',
      'battery' => 'Battery',
      _ => 'Unknown',
    };

String formatDeviceTimestamp(String? raw) {
  if (raw == null || raw.isEmpty) return 'Unavailable';
  final parsed = DateTime.tryParse(raw)?.toLocal();
  if (parsed == null) return raw;
  final yyyy = parsed.year.toString().padLeft(4, '0');
  final mm = parsed.month.toString().padLeft(2, '0');
  final dd = parsed.day.toString().padLeft(2, '0');
  final hh = parsed.hour.toString().padLeft(2, '0');
  final min = parsed.minute.toString().padLeft(2, '0');
  final sec = parsed.second.toString().padLeft(2, '0');
  return '$yyyy-$mm-$dd $hh:$min:$sec';
}

String _formatPlaybackTime(int milliseconds) {
  final totalSeconds = milliseconds.clamp(0, 1 << 31) ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
