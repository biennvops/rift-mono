import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/widgets/rift_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class NotificationsAndMediaScreen extends StatefulWidget {
  const NotificationsAndMediaScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<NotificationsAndMediaScreen> createState() => _NotificationsAndMediaScreenState();
}

class _NotificationsAndMediaScreenState extends State<NotificationsAndMediaScreen> with TickerProviderStateMixin {
  late final AnimationController _scanController;
  late final AnimationController _pulseController1;
  late final AnimationController _pulseController2;
  late final AnimationController _pulseController3;
  late final AnimationController _pulseController4;
  late final AnimationController _pulseController5;

  StreamSubscription<Map<String, dynamic>>? _postedMediaSub;
  StreamSubscription<Map<String, dynamic>>? _updatedMediaSub;
  StreamSubscription<Map<String, dynamic>>? _removedMediaSub;
  StreamSubscription<bool>? _connectionSub;

  StreamSubscription<Map<String, dynamic>>? _notifPostedSub;
  StreamSubscription<Map<String, dynamic>>? _notifUpdatedSub;
  StreamSubscription<Map<String, dynamic>>? _notifRemovedSub;
  StreamSubscription<Map<String, dynamic>>? _notifActionResultSub;

  final Map<String, Map<String, dynamic>> _playbacksByKey = <String, Map<String, dynamic>>{};
  final List<Map<String, dynamic>> _notifications = [];
  final Map<String, String> _peerNames = {};
  final List<Map<String, dynamic>> _auditLog = [];

  bool _isLoadingMedia = true;
  bool _isLoadingNotifs = true;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _pulseController1 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000), lowerBound: 0.1, upperBound: 0.8)..repeat(reverse: true);
    _pulseController2 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200), lowerBound: 0.2, upperBound: 0.9)..repeat(reverse: true);
    _pulseController3 = AnimationController(vsync: this, duration: const Duration(milliseconds: 800), lowerBound: 0.1, upperBound: 0.7)..repeat(reverse: true);
    _pulseController4 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500), lowerBound: 0.2, upperBound: 1.0)..repeat(reverse: true);
    _pulseController5 = AnimationController(vsync: this, duration: const Duration(milliseconds: 900), lowerBound: 0.1, upperBound: 0.6)..repeat(reverse: true);

    _addLogItem(Icons.login, 'Realtime Sync Initialized', 'Listening for Notifications & Media IPC events');

    final client = context.read<JsonRpcRiftClient>();
    
    // Media subscriptions
    _postedMediaSub = client.onMediaPlaybackPosted.listen(_onPlaybackPosted);
    _updatedMediaSub = client.onMediaPlaybackUpdated.listen(_onPlaybackUpdated);
    _removedMediaSub = client.onMediaPlaybackRemoved.listen(_onPlaybackRemoved);
    
    // Notification subscriptions
    _notifPostedSub = client.onNotificationPosted.listen((_) {
      if (mounted) unawaited(_refreshNotifications());
    });
    _notifUpdatedSub = client.onNotificationUpdated.listen((_) {
      if (mounted) unawaited(_refreshNotifications());
    });
    _notifRemovedSub = client.onNotificationRemoved.listen((_) {
      if (mounted) unawaited(_refreshNotifications());
    });
    _notifActionResultSub = client.onNotificationActionResult.listen((_) {
      if (mounted) unawaited(_refreshNotifications());
    });

    _connectionSub = client.onConnectionChanged.listen((isConnected) {
      if (isConnected && mounted) {
        unawaited(_loadAllData());
      }
    });

    unawaited(_loadAllData());
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
    _connectionSub?.cancel();

    _notifPostedSub?.cancel();
    _notifUpdatedSub?.cancel();
    _notifRemovedSub?.cancel();
    _notifActionResultSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    await _loadPeers();
    await Future.wait([
      _refreshPlaybacks(),
      _refreshNotifications(),
    ]);
  }

  Future<void> _loadPeers() async {
    try {
      final client = context.read<JsonRpcRiftClient>();
      final result = await client.listTrustedPeers();
      final peers = List<Map<String, dynamic>>.from(result['peers'] as List? ?? const <dynamic>[]);
      if (mounted) {
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
      }
    } catch (_) {}
  }

  String _resolvePeerName(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return 'Unknown Device';
    if (_peerNames.containsKey(deviceId)) return _peerNames[deviceId]!;
    if (deviceId.length <= 16) return deviceId;
    return '${deviceId.substring(0, 12)}...';
  }

  void _addLogItem(IconData icon, String title, String subtitle) {
    if (!mounted) return;
    setState(() {
      _auditLog.insert(0, {
        'icon': icon,
        'title': title,
        'subtitle': subtitle,
        'time': DateTime.now(),
      });
      if (_auditLog.length > 30) {
        _auditLog.removeLast();
      }
    });
  }

  Future<void> _refreshPlaybacks() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listMediaPlayback();
      final playbacks = List<Map<String, dynamic>>.from(
        (result['playbacks'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      if (!mounted) return;
      setState(() {
        _playbacksByKey
          ..clear()
          ..addEntries(playbacks.map((item) => MapEntry(_keyFor(item), item)));
        _isLoadingMedia = false;
      });
      _addLogItem(Icons.refresh, 'Media State Synchronized', 'Loaded ${_playbacksByKey.length} active stream(s)');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingMedia = false;
      });
      _addLogItem(Icons.error_outline, 'Sync Failed', 'Could not fetch media playbacks: $e');
    }
  }

  Future<void> _refreshNotifications() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listNotifications();
      final notifications = List<Map<String, dynamic>>.from(
        (result['notifications'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      notifications.sort((a, b) {
        final aTime = DateTime.tryParse(a['postedAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = DateTime.tryParse(b['postedAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
      if (!mounted) return;
      setState(() {
        _notifications
          ..clear()
          ..addAll(notifications.take(30));
        _isLoadingNotifs = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingNotifs = false;
      });
    }
  }

  void _onPlaybackPosted(Map<String, dynamic> playback) {
    if (!mounted) return;
    setState(() {
      _playbacksByKey[_keyFor(playback)] = Map<String, dynamic>.from(playback);
    });
    final title = playback['title']?.toString() ?? 'Audio Stream';
    final peerName = _resolvePeerName(playback['sourceDeviceId']?.toString());
    _addLogItem(Icons.play_circle_fill, 'Stream Detected: $title', 'Origin: $peerName');
  }

  void _onPlaybackUpdated(Map<String, dynamic> playback) {
    if (!mounted) return;
    setState(() {
      _playbacksByKey[_keyFor(playback)] = Map<String, dynamic>.from(playback);
    });
    final title = playback['title']?.toString() ?? 'Audio Stream';
    final state = playback['playbackState']?.toString() ?? 'updated';
    _addLogItem(Icons.sync, 'Stream Updated: $title', 'Status: ${state.toUpperCase()}');
  }

  void _onPlaybackRemoved(Map<String, dynamic> playback) {
    if (!mounted) return;
    final key = _keyFor(playback);
    final existing = _playbacksByKey.remove(key);
    setState(() {});
    final title = existing?['title']?.toString() ?? 'Audio Stream';
    _addLogItem(Icons.stop_circle, 'Stream Terminated', 'Stopped mirroring $title');
  }

  String _keyFor(Map<String, dynamic> playback) => '${playback['sourceDeviceId']}:${playback['playbackId']}';

  Map<String, dynamic>? _selectCurrentPlayback() {
    if (_playbacksByKey.isEmpty) return null;
    final candidates = _playbacksByKey.values.toList(growable: false)
      ..sort((a, b) {
        final left = DateTime.tryParse(a['updatedAt']?.toString() ?? '')?.toUtc();
        final right = DateTime.tryParse(b['updatedAt']?.toString() ?? '')?.toUtc();
        if (left == null && right == null) return 0;
        if (left == null) return 1;
        if (right == null) return -1;
        return right.compareTo(left);
      });
    for (final candidate in candidates) {
      if (candidate['playbackState']?.toString() != 'stopped') {
        return candidate;
      }
    }
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<void> _performAction(String action, [int? positionMs]) async {
    final current = _selectCurrentPlayback();
    if (current == null) return;
    final playbackId = current['playbackId']?.toString();
    if (playbackId == null || playbackId.isEmpty) return;

    final client = context.read<JsonRpcRiftClient>();
    try {
      await client.performMediaPlaybackAction(
        playbackId: playbackId,
        action: action,
        positionMs: positionMs,
      );
      _addLogItem(Icons.track_changes, 'Action Dispatched: ${action.toUpperCase()}', 'Target: $playbackId');
    } catch (e) {
      _addLogItem(Icons.error, 'Action Rejected: ${action.toUpperCase()}', JsonRpcRiftClient.formatDisplayError(e));
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: JsonRpcRiftClient.formatDisplayError(e),
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _performNotificationAction(Map<String, dynamic> notification, String action) async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      await client.performNotificationAction(
        notificationId: notification['notificationId']?.toString() ?? '',
        action: action,
      );
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: action == 'open' ? 'Notification opened on Android.' : 'Notification dismissed on Android.',
        type: RiftSnackbarType.success,
      );
      unawaited(_refreshNotifications());
    } catch (error) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: JsonRpcRiftClient.formatDisplayError(error),
        type: RiftSnackbarType.error,
      );
    }
  }

  String _formatDuration(int? totalMs) {
    if (totalMs == null || totalMs < 0) return '00:00';
    final duration = Duration(milliseconds: totalMs);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      final hours = duration.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = RefreshIndicator(
      onRefresh: _loadAllData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.onClose != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Notifications & Media', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface)),
                      const SizedBox(height: 4),
                      Text('Realtime mirrored notifications and active media sessions.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                    tooltip: 'Close Panel',
                    style: IconButton.styleFrom(
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Divider(color: theme.colorScheme.outlineVariant),
              const SizedBox(height: 24),
            ],

            // SECTION 1: MEDIA PLAYBACK
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('MIRRORED MEDIA PLAYBACK', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.secondary, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                if (_playbacksByKey.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('${_playbacksByKey.length} ACTIVE STREAM(S)', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_isLoadingMedia)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else
              _buildMediaSection(theme),

            const SizedBox(height: 36),

            // SECTION 2: NOTIFICATIONS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('ANDROID NOTIFICATIONS', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.secondary, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                IconButton(
                  onPressed: _refreshNotifications,
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Refresh Notifications',
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.all(4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_isLoadingNotifs)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else
              _buildNotificationsSection(theme),
          ],
        ),
      ),
    );

    if (widget.onClose == null) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          title: const Text('Notifications & Media'),
          backgroundColor: theme.colorScheme.surface,
          elevation: 0,
        ),
        body: content,
      );
    }

    return Container(
      color: theme.colorScheme.surface,
      child: content,
    );
  }

  Widget _buildMediaSection(ThemeData theme) {
    final current = _selectCurrentPlayback();
    if (current == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            Icon(Icons.speaker_group_outlined, size: 48, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 16),
            Text('No Active Media Stream', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Play music or video on a trusted peer device to mirror controls and audio status here.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _refreshPlaybacks,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Scan For Sessions'),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      );
    }

    final title = current['title']?.toString() ?? 'Audio Stream';
    final artist = current['artist']?.toString() ?? 'Unknown Artist';
    final album = current['album']?.toString() ?? 'Remote Album';
    final appName = current['appName']?.toString() ?? 'Media App';
    final sourceDeviceId = current['sourceDeviceId']?.toString();
    final sourceName = _resolvePeerName(sourceDeviceId);
    final state = current['playbackState']?.toString() ?? 'stopped';
    final isPlaying = state == 'playing';
    final positionMs = (current['positionMs'] as num?)?.toInt() ?? 0;
    final durationMs = (current['durationMs'] as num?)?.toInt() ?? 0;
    final canPlay = current['canPlay'] == true;
    final canPause = current['canPause'] == true;
    final canSkipNext = current['canSkipNext'] == true;
    final canSkipPrevious = current['canSkipPrevious'] == true;

    Uint8List? artworkBytes;
    final artworkMap = current['artwork'];
    if (artworkMap is Map) {
      final base64Str = artworkMap['data']?.toString() ?? artworkMap['contentBase64']?.toString();
      if (base64Str != null && base64Str.isNotEmpty) {
        try {
          artworkBytes = base64Decode(base64Str);
        } catch (_) {}
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 650;
        return Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 16, offset: const Offset(0, 4)),
                ],
              ),
              child: isCompact
                  ? Column(
                      children: [
                        _buildArtworkPanel(theme, artworkBytes, appName, sourceName, true),
                        _buildControlsPanel(theme, title, artist, album, isPlaying, positionMs, durationMs, canPlay, canPause, canSkipNext, canSkipPrevious),
                      ],
                    )
                  : IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 5, child: _buildArtworkPanel(theme, artworkBytes, appName, sourceName, false)),
                          Container(width: 1, color: theme.colorScheme.outlineVariant),
                          Expanded(flex: 7, child: _buildControlsPanel(theme, title, artist, album, isPlaying, positionMs, durationMs, canPlay, canPause, canSkipNext, canSkipPrevious)),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            _buildAuditLogExpander(theme),
          ],
        );
      },
    );
  }

  Widget _buildArtworkPanel(ThemeData theme, Uint8List? artworkBytes, String appName, String sourceName, bool isCompact) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: isCompact ? const BorderRadius.vertical(top: Radius.circular(16)) : const BorderRadius.horizontal(left: Radius.circular(16)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: isCompact ? 160 : 200,
            height: isCompact ? 160 : 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surfaceContainerHighest,
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 6))],
            ),
            clipBehavior: Clip.antiAlias,
            child: artworkBytes != null
                ? Image.memory(artworkBytes, fit: BoxFit.cover)
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [theme.colorScheme.primaryContainer, theme.colorScheme.surfaceContainerHighest],
                          ),
                        ),
                      ),
                      Icon(Icons.music_note, size: 64, color: theme.colorScheme.primary.withValues(alpha: 0.5)),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.devices, size: 14, color: theme.colorScheme.secondary),
              const SizedBox(width: 6),
              Flexible(child: Text(sourceName, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.secondary, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 4),
          Text(appName, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildControlsPanel(ThemeData theme, String title, String artist, String album, bool isPlaying, int positionMs, int durationMs, bool canPlay, bool canPause, bool canSkipNext, bool canSkipPrevious) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isPlaying ? theme.colorScheme.primaryContainer.withValues(alpha: 0.2) : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: isPlaying ? theme.colorScheme.primary.withValues(alpha: 0.3) : theme.colorScheme.outlineVariant),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isPlaying ? theme.colorScheme.primary : theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(isPlaying ? 'STREAMING ACTIVE' : 'STREAM PAUSED', style: theme.textTheme.labelSmall?.copyWith(color: isPlaying ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Icon(Icons.surround_sound, color: theme.colorScheme.outlineVariant),
                ],
              ),
              const SizedBox(height: 20),
              Text(title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(artist, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(album, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),

          const SizedBox(height: 24),

          Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formatDuration(positionMs), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.secondary, fontWeight: FontWeight.bold)),
                  Text(_formatDuration(durationMs), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.secondary, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  color: theme.colorScheme.primary,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: canSkipPrevious ? () => _performAction('previous') : null,
                    icon: const Icon(Icons.skip_previous),
                    iconSize: 32,
                    color: theme.colorScheme.onSurface,
                  ),
                  const SizedBox(width: 16),
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary,
                      boxShadow: [BoxShadow(color: theme.colorScheme.primary.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
                    ),
                    child: IconButton(
                      onPressed: isPlaying ? (canPause ? () => _performAction('pause') : null) : (canPlay ? () => _performAction('play') : null),
                      icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                      iconSize: 32,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    onPressed: canSkipNext ? () => _performAction('next') : null,
                    icon: const Icon(Icons.skip_next),
                    iconSize: 32,
                    color: theme.colorScheme.onSurface,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAuditLogExpander(ThemeData theme) {
    return ExpansionTile(
      title: Text('Session Audit Log (${_auditLog.length})', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      leading: Icon(Icons.history_toggle_off, size: 20, color: theme.colorScheme.outline),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: theme.colorScheme.outlineVariant)),
      collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: theme.colorScheme.outlineVariant)),
      children: [
        if (_auditLog.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('No media sync events recorded in this session.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _auditLog.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, idx) {
              final item = _auditLog[idx];
              return Row(
                children: [
                  Icon(item['icon'] as IconData, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item['title'] as String, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                        Text(item['subtitle'] as String, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildNotificationsSection(ThemeData theme) {
    if (_notifications.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            Icon(Icons.notifications_off_outlined, size: 48, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 16),
            Text('No Mirrored Notifications', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'When trusted mobile devices receive notifications, they will be securely mirrored and actionable here.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Column(
      children: _notifications.map((notification) {
        final title = notification['title']?.toString().trim();
        final body = notification['bodyPreview']?.toString().trim();
        final appName = notification['appName']?.toString() ?? 'App';
        final packageName = notification['packageName']?.toString() ?? 'unknown.package';
        final sourceName = _resolvePeerName(notification['sourceDeviceId']?.toString());
        final isRemoved = notification['isRemoved'] == true;
        final canOpen = !isRemoved && notification['isOpenable'] == true;
        final canDismiss = !isRemoved && notification['isDismissible'] == true;

        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      title == null || title.isEmpty ? appName : title,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(sourceName, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.secondary, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$appName • $packageName',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (body != null && body.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (canOpen)
                    FilledButton.tonalIcon(
                      onPressed: () => _performNotificationAction(notification, 'open'),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Open on Device'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  if (canDismiss || isRemoved)
                    OutlinedButton.icon(
                      onPressed: canDismiss ? () => _performNotificationAction(notification, 'dismiss') : null,
                      icon: Icon(isRemoved ? Icons.check : Icons.close, size: 16),
                      label: Text(isRemoved ? 'Dismissed' : 'Dismiss'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      }).toList(growable: false),
    );
  }
}
