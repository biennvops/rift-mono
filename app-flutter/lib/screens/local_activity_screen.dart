import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ui/local_events_notifier.dart';
import '../src/ui/theme.dart';

class LocalActivityScreen extends StatelessWidget {
  const LocalActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 560,
                maxHeight: 640,
              ),
              child: Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: LocalActivityPanel(
                  onClose: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LocalActivityPanel extends StatefulWidget {
  const LocalActivityPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<LocalActivityPanel> createState() => _LocalActivityPanelState();
}

class _LocalActivityPanelState extends State<LocalActivityPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<LocalEventsNotifier>().markAllRead();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final events = context.watch<LocalEventsNotifier>().events;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.onClose != null)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.notifications_outlined,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Rift Activity',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 18),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.all(4),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: events.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(RiftDesign.spaceXl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.notifications_none,
                            size: 48, color: theme.colorScheme.outlineVariant),
                        const SizedBox(height: RiftDesign.spaceMd),
                        Text(
                          'No local activity',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: events.length,
                  itemBuilder: (context, index) =>
                      _ActivityTile(event: events[index]),
                ),
        ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.event});

  final LocalEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (event.kind) {
      LocalEventKind.deviceTrusted ||
      LocalEventKind.fileReceived =>
        RiftDesign.success,
      LocalEventKind.deviceDisconnected ||
      LocalEventKind.fileFailed =>
        theme.colorScheme.error,
      LocalEventKind.devicePairingRequest => theme.colorScheme.tertiary,
      LocalEventKind.clipboardReceived => theme.colorScheme.primary,
      _ => theme.colorScheme.outline,
    };
    final icon = switch (event.kind) {
      LocalEventKind.deviceConnected => Icons.wifi_find,
      LocalEventKind.deviceDisconnected => Icons.block,
      LocalEventKind.deviceTrusted => Icons.verified,
      LocalEventKind.devicePairingRequest => Icons.link,
      LocalEventKind.clipboardReceived => Icons.content_paste,
      LocalEventKind.clipboardExpired => Icons.timer_off,
      LocalEventKind.fileReceived => Icons.download_done,
      LocalEventKind.fileFailed => Icons.error_outline,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.title,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  if (event.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      event.subtitle,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatTime(event.time),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
