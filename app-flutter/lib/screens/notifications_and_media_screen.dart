import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import '../src/ui/local_events_notifier.dart';
import '../widgets/rift_snackbar.dart';

/// Full-page view of the Local Events feed, opened from the mobile bell icon.
class NotificationsAndMediaScreen extends StatelessWidget {
  const NotificationsAndMediaScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = LocalEventsPanel(onClose: onClose);

    if (onClose == null) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          title: const Text('Notifications'),
          backgroundColor: theme.colorScheme.surface,
          elevation: 0,
        ),
        body: content,
      );
    }
    return content;
  }
}

/// Reusable panel — used in the desktop popover AND the full mobile screen.
class LocalEventsPanel extends StatefulWidget {
  const LocalEventsPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<LocalEventsPanel> createState() => _LocalEventsPanelState();
}

class _LocalEventsPanelState extends State<LocalEventsPanel>
    with TickerProviderStateMixin {
  late final AnimationController _scanController;
  late final AnimationController _pulseController1;
  late final AnimationController _pulseController2;
  late final AnimationController _pulseController3;
  late final AnimationController _pulseController4;
  late final AnimationController _pulseController5;

  // Media playback state (cross-device status only)
  final Map<String, Map<String, dynamic>> _playbacksByKey = {};
  StreamSubscription<Map<String, dynamic>>? _postedMediaSub;
  StreamSubscription<Map<String, dynamic>>? _updatedMediaSub;
  StreamSubscription<Map<String, dynamic>>? _removedMediaSub;
  final Map<String, String> _peerNames = {};

  @override
  void initState() {
    super.initState();
    _scanController =
        AnimationController(vsync: this, duration: const Duration(seconds: 4))
          ..repeat();
    _pulseController1 = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1000),
        lowerBound: 0.1,
        upperBound: 0.8)
      ..repeat(reverse: true);
    _pulseController2 = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
        lowerBound: 0.2,
        upperBound: 0.9)
      ..repeat(reverse: true);
    _pulseController3 = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 800),
        lowerBound: 0.1,
        upperBound: 0.7)
      ..repeat(reverse: true);
    _pulseController4 = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1500),
        lowerBound: 0.2,
        upperBound: 1.0)
      ..repeat(reverse: true);
    _pulseController5 = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
        lowerBound: 0.1,
        upperBound: 0.6)
      ..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<LocalEventsNotifier>().markAllRead();
      _bindMediaStreams();
      _loadPeers();
    });
  }

  void _bindMediaStreams() {
    final client = context.read<JsonRpcRiftClient>();
    _postedMediaSub = client.onMediaPlaybackPosted.listen(_onMediaPosted);
    _updatedMediaSub = client.onMediaPlaybackUpdated.listen(_onMediaUpdated);
    _removedMediaSub = client.onMediaPlaybackRemoved.listen(_onMediaRemoved);
  }

  Future<void> _loadPeers() async {
    try {
      final client = context.read<JsonRpcRiftClient>();
      final result = await client.listTrustedPeers();
      final peers = List<Map<String, dynamic>>.from(
          result['peers'] as List? ?? const <dynamic>[]);
      if (!mounted) return;
      setState(() {
        _peerNames.clear();
        for (final p in peers) {
          final id = p['deviceId']?.toString();
          final name = p['displayName']?.toString();
          if (id != null && name != null && name.isNotEmpty) {
            _peerNames[id] = name;
          }
        }
      });
      // Also prefetch current media sessions
      final result2 = await client.listMediaPlayback();
      final playbacks = List<Map<String, dynamic>>.from(
        (result2['playbacks'] as List? ?? const <dynamic>[])
            .map((item) => Map<String, dynamic>.from(item as Map)),
      );
      if (!mounted) return;
      setState(() {
        _playbacksByKey
          ..clear()
          ..addEntries(playbacks.map((p) => MapEntry(_keyFor(p), p)));
      });
    } catch (_) {}
  }

  String _keyFor(Map<String, dynamic> p) =>
      '${p['sourceDeviceId']}:${p['playbackId']}';

  String _peerName(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return 'Unknown';
    return _peerNames[deviceId] ??
        (deviceId.length > 12 ? '${deviceId.substring(0, 12)}…' : deviceId);
  }

  void _onMediaPosted(Map<String, dynamic> p) {
    if (!mounted) return;
    setState(() => _playbacksByKey[_keyFor(p)] = Map.from(p));
  }

  void _onMediaUpdated(Map<String, dynamic> p) {
    if (!mounted) return;
    setState(() => _playbacksByKey[_keyFor(p)] = Map.from(p));
  }

  void _onMediaRemoved(Map<String, dynamic> p) {
    if (!mounted) return;
    setState(() => _playbacksByKey.remove(_keyFor(p)));
  }

  @override
  void dispose() {
    _scanController.dispose();
    _pulseController1.dispose();
    _pulseController2.dispose();
    _pulseController3.dispose();
    _pulseController4.dispose();
    _pulseController5.dispose();
    _postedMediaSub?.cancel();
    _updatedMediaSub?.cancel();
    _removedMediaSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = context.watch<LocalEventsNotifier>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.onClose != null) _buildHeader(theme),
        if (_playbacksByKey.isNotEmpty) ...[
          _buildMediaStatusBar(theme),
        ],
        Expanded(
          child: notifier.events.isEmpty
              ? _buildEmpty(theme)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: notifier.events.length,
                  itemBuilder: (context, index) =>
                      _buildEventTile(theme, notifier.events[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.notifications_outlined,
              size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Text(
            'Notifications',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (widget.onClose != null)
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
    );
  }

  Widget _buildMediaStatusBar(ThemeData theme) {
    final active = _playbacksByKey.values
        .where((p) => p['playbackState'] == 'playing')
        .toList();
    final current =
        active.isNotEmpty ? active.first : _playbacksByKey.values.first;
    final deviceName = _peerName(current['sourceDeviceId']?.toString());
    final title = current['title']?.toString() ?? 'media';
    final isPlaying = current['playbackState'] == 'playing';

    Uint8List? artworkBytes;
    final artworkMap = current['artwork'];
    if (artworkMap is Map) {
      final base64Str = artworkMap['data']?.toString() ??
          artworkMap['contentBase64']?.toString();
      if (base64Str != null && base64Str.isNotEmpty) {
        try {
          artworkBytes = base64Decode(base64Str);
        } catch (_) {}
      }
    }

    return InkWell(
      onTap: () => _showMediaDetailSheet(context, current),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.06),
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              clipBehavior: Clip.antiAlias,
              child: artworkBytes != null
                  ? Image.memory(artworkBytes, fit: BoxFit.cover)
                  : Icon(Icons.music_note,
                      size: 18, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    isPlaying
                        ? 'Playing on $deviceName'
                        : 'Paused on $deviceName',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            AnimatedBuilder(
              animation: _pulseController1,
              builder: (context, _) => Icon(
                Icons.graphic_eq,
                size: 18,
                color: isPlaying
                    ? theme.colorScheme.primary
                        .withValues(alpha: _pulseController1.value)
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right,
                size: 16, color: theme.colorScheme.outlineVariant),
          ],
        ),
      ),
    );
  }

  void _showMediaDetailSheet(
      BuildContext context, Map<String, dynamic> playback) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MediaControlSheet(
        playback: playback,
        peerName: _peerName(playback['sourceDeviceId']?.toString()),
      ),
    );
  }

  Widget _buildEventTile(ThemeData theme, LocalEvent event) {
    final icon = _iconForKind(event.kind);
    final color = _colorForKind(theme, event.kind);
    final timeLabel = _formatTime(event.time);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {},
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
                    Text(
                      event.title,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (event.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        event.subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                timeLabel,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none,
                size: 48, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(
              'No events',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForKind(LocalEventKind kind) {
    switch (kind) {
      case LocalEventKind.deviceConnected:
        return Icons.wifi_find;
      case LocalEventKind.deviceDisconnected:
        return Icons.block;
      case LocalEventKind.deviceTrusted:
        return Icons.verified;
      case LocalEventKind.devicePairingRequest:
        return Icons.link;
      case LocalEventKind.clipboardReceived:
        return Icons.content_paste;
      case LocalEventKind.clipboardExpired:
        return Icons.timer_off;
      case LocalEventKind.fileReceived:
        return Icons.download_done;
      case LocalEventKind.fileFailed:
        return Icons.error_outline;
      case LocalEventKind.notificationFromPeer:
        return Icons.notifications_active_outlined;
      case LocalEventKind.mediaPlayingOnPeer:
        return Icons.play_circle_outline;
      case LocalEventKind.mediaStoppedOnPeer:
        return Icons.stop_circle_outlined;
    }
  }

  Color _colorForKind(ThemeData theme, LocalEventKind kind) {
    switch (kind) {
      case LocalEventKind.deviceTrusted:
      case LocalEventKind.fileReceived:
        return const Color(0xFF10B981);
      case LocalEventKind.deviceDisconnected:
      case LocalEventKind.fileFailed:
        return theme.colorScheme.error;
      case LocalEventKind.devicePairingRequest:
        return theme.colorScheme.tertiary;
      case LocalEventKind.clipboardReceived:
      case LocalEventKind.mediaPlayingOnPeer:
        return theme.colorScheme.primary;
      default:
        return theme.colorScheme.outline;
    }
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

// ---------------------------------------------------------------------------
// Compact media control sheet (shown when user taps the media status bar)
// ---------------------------------------------------------------------------

class _MediaControlSheet extends StatefulWidget {
  const _MediaControlSheet({
    required this.playback,
    required this.peerName,
  });

  final Map<String, dynamic> playback;
  final String peerName;

  @override
  State<_MediaControlSheet> createState() => _MediaControlSheetState();
}

class _MediaControlSheetState extends State<_MediaControlSheet> {
  late Map<String, dynamic> _playback;
  StreamSubscription<Map<String, dynamic>>? _updatedSub;
  StreamSubscription<Map<String, dynamic>>? _removedSub;

  @override
  void initState() {
    super.initState();
    _playback = widget.playback;
    final client = context.read<JsonRpcRiftClient>();
    final key = '${_playback['sourceDeviceId']}:${_playback['playbackId']}';
    _updatedSub = client.onMediaPlaybackUpdated.listen((p) {
      if (!mounted) return;
      if ('${p['sourceDeviceId']}:${p['playbackId']}' == key) {
        setState(() => _playback = Map.from(p));
      }
    });
    _removedSub = client.onMediaPlaybackRemoved.listen((p) {
      if (!mounted) return;
      if ('${p['sourceDeviceId']}:${p['playbackId']}' == key) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _updatedSub?.cancel();
    _removedSub?.cancel();
    super.dispose();
  }

  Future<void> _action(String action) async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      await client.performMediaPlaybackAction(
        playbackId: _playback['playbackId']?.toString() ?? '',
        action: action,
      );
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: JsonRpcRiftClient.formatDisplayError(e),
        type: RiftSnackbarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _playback['title']?.toString() ?? 'Unknown';
    final artist = _playback['artist']?.toString() ?? '';
    final isPlaying = _playback['playbackState'] == 'playing';
    final canPlay = _playback['canPlay'] == true;
    final canPause = _playback['canPause'] == true;
    final canNext = _playback['canSkipNext'] == true;
    final canPrev = _playback['canSkipPrevious'] == true;
    final positionMs = (_playback['positionMs'] as num?)?.toInt() ?? 0;
    final durationMs = (_playback['durationMs'] as num?)?.toInt() ?? 0;

    Uint8List? artworkBytes;
    final artworkMap = _playback['artwork'];
    if (artworkMap is Map) {
      final base64Str = artworkMap['data']?.toString() ??
          artworkMap['contentBase64']?.toString();
      if (base64Str != null && base64Str.isNotEmpty) {
        try {
          artworkBytes = base64Decode(base64Str);
        } catch (_) {}
      }
    }

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(
            top: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: artworkBytes != null
                      ? Image.memory(artworkBytes, fit: BoxFit.cover)
                      : Icon(Icons.music_note,
                          size: 28, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (artist.isNotEmpty)
                        Text(
                          artist,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      Text(
                        'On ${widget.peerName}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (durationMs > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (positionMs / durationMs).clamp(0.0, 1.0),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  color: theme.colorScheme.primary,
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmtMs(positionMs),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  Text(_fmtMs(durationMs),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: canPrev ? () => _action('previous') : null,
                  icon: const Icon(Icons.skip_previous),
                  iconSize: 32,
                ),
                const SizedBox(width: 8),
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.primary,
                  ),
                  child: IconButton(
                    onPressed: isPlaying
                        ? (canPause ? () => _action('pause') : null)
                        : (canPlay ? () => _action('play') : null),
                    icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                    iconSize: 28,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: canNext ? () => _action('next') : null,
                  icon: const Icon(Icons.skip_next),
                  iconSize: 32,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
