import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import '../src/notification_icon.dart';
import '../src/ui/theme.dart';
import '../widgets/rift_snackbar.dart';

class NotificationsAndMediaScreen extends StatefulWidget {
  const NotificationsAndMediaScreen({super.key});

  @override
  State<NotificationsAndMediaScreen> createState() =>
      _NotificationsAndMediaScreenState();
}

class _NotificationsAndMediaScreenState
    extends State<NotificationsAndMediaScreen> {
  final Map<String, Map<String, dynamic>> _notifications = {};
  final Map<String, Map<String, dynamic>> _playbacks = {};
  final Map<String, String> _peerNames = {};
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  bool _loading = true;
  String? _error;

  JsonRpcRiftClient get _client => context.read<JsonRpcRiftClient>();

  @override
  void initState() {
    super.initState();
    _subscriptions.addAll([
      _client.onNotificationPosted.listen(_upsertNotification),
      _client.onNotificationUpdated.listen(_upsertNotification),
      _client.onNotificationRemoved.listen(_removeNotification),
      _client.onMediaPlaybackPosted.listen(_upsertPlayback),
      _client.onMediaPlaybackUpdated.listen(_upsertPlayback),
      _client.onMediaPlaybackRemoved.listen(_removePlayback),
    ]);
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  String _notificationKey(Map<String, dynamic> item) =>
      '${item['sourceDeviceId']}:${item['notificationId']}';

  String _playbackKey(Map<String, dynamic> item) =>
      '${item['sourceDeviceId']}:${item['playbackId']}';

  void _upsertNotification(Map<String, dynamic> item) {
    if (!mounted) return;
    setState(() => _notifications[_notificationKey(item)] = Map.of(item));
  }

  void _removeNotification(Map<String, dynamic> item) {
    if (!mounted) return;
    setState(() => _notifications.remove(_notificationKey(item)));
  }

  void _upsertPlayback(Map<String, dynamic> item) {
    if (!mounted) return;
    setState(() => _playbacks[_playbackKey(item)] = Map.of(item));
  }

  void _removePlayback(Map<String, dynamic> item) {
    if (!mounted) return;
    setState(() => _playbacks.remove(_playbackKey(item)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _client.listTrustedPeers(),
        _client.listNotifications(),
        _client.listMediaPlayback(),
      ]);
      final peers = List<Map<String, dynamic>>.from(
        results[0]['peers'] as List? ?? const <dynamic>[],
      );
      final notifications = List<Map<String, dynamic>>.from(
        results[1]['notifications'] as List? ?? const <dynamic>[],
      );
      final playbacks = List<Map<String, dynamic>>.from(
        results[2]['playbacks'] as List? ?? const <dynamic>[],
      );
      if (!mounted) return;
      setState(() {
        _peerNames
          ..clear()
          ..addEntries(peers.map((peer) {
            final id = peer['deviceId']?.toString() ?? '';
            final name = peer['displayName']?.toString();
            return MapEntry(
                id, name?.isNotEmpty == true ? name! : _shortId(id));
          }));
        _notifications
          ..clear()
          ..addEntries(notifications
              .map((item) => MapEntry(_notificationKey(item), item)));
        _playbacks
          ..clear()
          ..addEntries(
              playbacks.map((item) => MapEntry(_playbackKey(item), item)));
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = JsonRpcRiftClient.formatDisplayError(error);
      });
    }
  }

  String _peerName(String? id) {
    if (id == null || id.isEmpty) return 'Unknown device';
    return _peerNames[id] ?? _shortId(id);
  }

  String _shortId(String id) => id.length > 12 ? '${id.substring(0, 12)}…' : id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          title: const Text('Notifications & Media'),
          backgroundColor: theme.colorScheme.surface,
          actions: [
            IconButton(
              onPressed: _loading ? null : _load,
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.notifications_outlined), text: 'Inbox'),
              Tab(icon: Icon(Icons.music_note_outlined), text: 'Media'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorState(message: _error!, onRetry: _load)
                : TabBarView(
                    children: [
                      _NotificationsTab(
                        notifications: _notifications.values.toList(),
                        peerName: _peerName,
                      ),
                      _MediaTab(
                        playbacks: _playbacks.values.toList(),
                        peerName: _peerName,
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _NotificationsTab extends StatelessWidget {
  const _NotificationsTab({
    required this.notifications,
    required this.peerName,
  });

  final List<Map<String, dynamic>> notifications;
  final String Function(String?) peerName;

  @override
  Widget build(BuildContext context) {
    if (notifications.isEmpty) {
      return const _EmptyState(
        icon: Icons.notifications_none,
        title: 'No mirrored notifications',
        subtitle: 'Notifications from trusted devices will appear here.',
      );
    }
    final items = [...notifications]..sort((a, b) =>
        (b['postedAt']?.toString() ?? '')
            .compareTo(a['postedAt']?.toString() ?? ''));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _NotificationCard(
        notification: items[index],
        peerName: peerName(items[index]['sourceDeviceId']?.toString()),
      ),
    );
  }
}

class _NotificationCard extends StatefulWidget {
  const _NotificationCard({
    required this.notification,
    required this.peerName,
  });

  final Map<String, dynamic> notification;
  final String peerName;

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  String? _pendingAction;

  Future<void> _perform(String action) async {
    final sourceDeviceId = widget.notification['sourceDeviceId']?.toString();
    final notificationId = widget.notification['notificationId']?.toString();
    if (sourceDeviceId == null ||
        sourceDeviceId.isEmpty ||
        notificationId == null ||
        notificationId.isEmpty) {
      RiftSnackbar.show(
        context: context,
        message: 'This notification has no valid source identity.',
        type: RiftSnackbarType.error,
      );
      return;
    }

    setState(() => _pendingAction = action);
    try {
      await context.read<JsonRpcRiftClient>().performNotificationAction(
            sourceDeviceId: sourceDeviceId,
            notificationId: notificationId,
            action: action,
          );
    } catch (error) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: JsonRpcRiftClient.formatDisplayError(error),
          type: RiftSnackbarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _pendingAction = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.notification;
    final appName = item['appName']?.toString() ?? 'App';
    final title = item['title']?.toString();
    final body = item['bodyPreview']?.toString();
    final busy = _pendingAction != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                NotificationAppIcon(
                  metadata: item['icon'],
                  size: 44,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(appName,
                          style: theme.textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        widget.peerName,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const _TrustedChip(),
              ],
            ),
            if (title?.isNotEmpty == true) ...[
              const SizedBox(height: 12),
              Text(title!, style: theme.textTheme.titleSmall),
            ],
            if (body?.isNotEmpty == true) ...[
              const SizedBox(height: 4),
              Text(body!, style: theme.textTheme.bodyMedium),
            ],
            if (item['isOpenable'] == true ||
                item['isDismissible'] == true) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (item['isOpenable'] == true)
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : () => _perform('open'),
                      icon: _pendingAction == 'open'
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open'),
                    ),
                  if (item['isDismissible'] == true)
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => _perform('dismiss'),
                      icon: _pendingAction == 'dismiss'
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.close, size: 18),
                      label: const Text('Dismiss'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MediaTab extends StatelessWidget {
  const _MediaTab({required this.playbacks, required this.peerName});

  final List<Map<String, dynamic>> playbacks;
  final String Function(String?) peerName;

  @override
  Widget build(BuildContext context) {
    if (playbacks.isEmpty) {
      return const _EmptyState(
        icon: Icons.music_off_outlined,
        title: 'Nothing playing',
        subtitle: 'Media sessions from trusted devices will appear here.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: playbacks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _MediaCard(
        playback: playbacks[index],
        peerName: peerName(playbacks[index]['sourceDeviceId']?.toString()),
      ),
    );
  }
}

class _MediaCard extends StatefulWidget {
  const _MediaCard({required this.playback, required this.peerName});

  final Map<String, dynamic> playback;
  final String peerName;

  @override
  State<_MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<_MediaCard> {
  bool _busy = false;

  Future<void> _perform(String action, {int? positionMs}) async {
    setState(() => _busy = true);
    try {
      await context.read<JsonRpcRiftClient>().performMediaPlaybackAction(
            playbackId: widget.playback['playbackId']?.toString() ?? '',
            sourceDeviceId: widget.playback['sourceDeviceId']?.toString() ?? '',
            action: action,
            positionMs: positionMs,
          );
    } catch (error) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: JsonRpcRiftClient.formatDisplayError(error),
          type: RiftSnackbarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.playback;
    final isPlaying = item['playbackState'] == 'playing';
    final position = (item['positionMs'] as num?)?.toInt() ?? 0;
    final duration = (item['durationMs'] as num?)?.toInt() ?? 0;
    final canSeek = item['canSeek'] == true && duration > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(RiftDesign.radius),
                  ),
                  child: Icon(Icons.music_note,
                      color: theme.colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['title']?.toString() ?? 'Unknown media',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        item['artist']?.toString() ??
                            item['appName']?.toString() ??
                            '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(widget.peerName,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.primary)),
                    ],
                  ),
                ),
                const _TrustedChip(),
              ],
            ),
            if (duration > 0) ...[
              const SizedBox(height: 12),
              Slider(
                value: position.clamp(0, duration).toDouble(),
                max: duration.toDouble(),
                onChanged: canSeek && !_busy ? (_) {} : null,
                onChangeEnd: canSeek && !_busy
                    ? (value) => _perform('seek', positionMs: value.round())
                    : null,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formatDuration(position)),
                  Text(_formatDuration(duration)),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: item['canSkipPrevious'] == true && !_busy
                      ? () => _perform('previous')
                      : null,
                  tooltip: 'Previous',
                  icon: const Icon(Icons.skip_previous),
                ),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : isPlaying
                          ? item['canPause'] == true
                              ? () => _perform('pause')
                              : null
                          : item['canPlay'] == true
                              ? () => _perform('play')
                              : null,
                  style: FilledButton.styleFrom(shape: const CircleBorder()),
                  child: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  onPressed: item['canSkipNext'] == true && !_busy
                      ? () => _perform('next')
                      : null,
                  tooltip: 'Next',
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _TrustedChip extends StatelessWidget {
  const _TrustedChip();

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.verified_user_outlined, size: 16),
      label: const Text('Trusted'),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
      backgroundColor: RiftDesign.success.withValues(alpha: 0.1),
      labelStyle: TextStyle(color: RiftDesign.success),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sync_problem, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
