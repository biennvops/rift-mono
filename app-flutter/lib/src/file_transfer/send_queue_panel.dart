import 'package:flutter/material.dart';

enum SendQueueStatus {
  queued('QUEUED'),
  sending('SENDING'),
  sent('SENT'),
  failed('FAILED');

  const SendQueueStatus(this.label);

  final String label;
}

class SendQueueItemData {
  const SendQueueItemData({
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
    required this.status,
    this.bytesTransferred = 0,
    this.errorMessage,
  });

  final String fileName;
  final String mediaType;
  final int byteSize;
  final int bytesTransferred;
  final SendQueueStatus status;
  final String? errorMessage;
}

class SendQueuePanel extends StatelessWidget {
  const SendQueuePanel({
    super.key,
    required this.items,
    required this.onRemove,
    required this.onRetry,
  });

  final List<SendQueueItemData> items;
  final ValueChanged<int> onRemove;
  final ValueChanged<int> onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          'Chua co file nao trong hang doi. Hay them file truoc khi gui.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Send Queue',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < items.length; index += 1)
          _SendQueueTile(
            item: items[index],
            onRemove: () => onRemove(index),
            onRetry: () => onRetry(index),
          ),
      ],
    );
  }
}

class _SendQueueTile extends StatelessWidget {
  const _SendQueueTile({
    required this.item,
    required this.onRemove,
    required this.onRetry,
  });

  final SendQueueItemData item;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _statusColor(theme, item.status);
    final progress = item.byteSize <= 0
        ? 0.0
        : (item.bytesTransferred / item.byteSize).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _mediaTypeIcon(item.mediaType),
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.fileName,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatSize(item.byteSize)} • ${item.mediaType}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (item.status == SendQueueStatus.sending) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress),
                ],
                if (item.errorMessage != null &&
                    item.errorMessage!.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.errorMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  item.status.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (item.status == SendQueueStatus.failed)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                )
              else
                IconButton(
                  tooltip: 'Remove from queue',
                  onPressed:
                      item.status == SendQueueStatus.sending ? null : onRemove,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static Color _statusColor(ThemeData theme, SendQueueStatus status) {
    switch (status) {
      case SendQueueStatus.sent:
        return theme.colorScheme.secondary;
      case SendQueueStatus.failed:
        return theme.colorScheme.error;
      case SendQueueStatus.sending:
        return theme.colorScheme.primary;
      case SendQueueStatus.queued:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  static IconData _mediaTypeIcon(String? mediaType) {
    final normalized = mediaType?.toLowerCase() ?? '';
    if (normalized.startsWith('video/')) return Icons.movie;
    if (normalized.startsWith('image/')) return Icons.image;
    if (normalized.startsWith('audio/')) return Icons.audiotrack;
    if (normalized == 'application/pdf') return Icons.picture_as_pdf;
    if (normalized.contains('zip') ||
        normalized.contains('tar') ||
        normalized.contains('7z') ||
        normalized.contains('gzip')) {
      return Icons.archive;
    }
    if (normalized.startsWith('text/')) return Icons.description;
    return Icons.insert_drive_file;
  }

  static String _formatSize(num rawBytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = rawBytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final formatted = value >= 10 || unitIndex == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$formatted ${units[unitIndex]}';
  }
}
