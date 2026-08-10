import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';
import 'event_log_screen.dart';
import '../src/ui/theme.dart';
import 'blocked_peers_screen.dart';

class SecurityDashboardScreen extends StatefulWidget {
  const SecurityDashboardScreen({super.key});

  @override
  State<SecurityDashboardScreen> createState() =>
      _SecurityDashboardScreenState();
}

class _SecurityDashboardScreenState extends State<SecurityDashboardScreen> {
  bool _isLoading = true;
  String? _error;

  int _trustedCount = 0;
  int _blockedCount = 0;
  int _pendingCount = 0;
  int _discoveredCount = 0;

  List<Map<String, dynamic>> _trustedPeers = [];
  List<Map<String, dynamic>> _discoveredPeers = [];
  List<Map<String, dynamic>> _recentEvents = [];
  Map<String, dynamic>? _criticalAlert;

  StreamSubscription<Map<String, dynamic>>? _securitySub;
  StreamSubscription<Map<String, dynamic>>? _trustSub;
  StreamSubscription<Map<String, dynamic>>? _peerDiscoveredSub;
  StreamSubscription<Map<String, dynamic>>? _peerLostSub;
  StreamSubscription<bool>? _connectionSub;
  bool _isReloading = false;
  bool _reloadQueued = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      _bindEvents();
    });
  }

  @override
  void dispose() {
    _securitySub?.cancel();
    _trustSub?.cancel();
    _peerDiscoveredSub?.cancel();
    _peerLostSub?.cancel();
    _connectionSub?.cancel();
    super.dispose();
  }

  void _bindEvents() {
    final client = context.read<JsonRpcRiftClient>();
    _securitySub = client.onSecurityEvent.listen((event) {
      if (!mounted) return;
      _scheduleReload();
    });
    _trustSub = client.onTrustChanged.listen((event) {
      if (!mounted) return;
      _scheduleReload();
    });
    _peerDiscoveredSub = client.onPeerDiscovered.listen((event) {
      if (!mounted) return;
      _scheduleReload();
    });
    _peerLostSub = client.onPeerLost.listen((event) {
      if (!mounted) return;
      _scheduleReload();
    });
    _connectionSub = client.onConnectionChanged.listen((isConnected) {
      if (!mounted) return;
      if (isConnected) {
        _scheduleReload();
        return;
      }
      setState(() {
        _error = 'Daemon not connected.';
      });
    });
  }

  void _scheduleReload() {
    if (_isReloading) {
      _reloadQueued = true;
      return;
    }
    _loadData();
  }

  bool _isSecurityEvent(Map<String, dynamic> event) {
    final eventType = event['eventType']?.toString() ?? '';
    final severity = event['severity']?.toString() ?? '';
    return eventType.startsWith('pairing') ||
        eventType.startsWith('trust') ||
        eventType.startsWith('auth') ||
        severity == 'critical' ||
        severity == 'error';
  }

  bool _isErrorEvent(Map<String, dynamic> event) {
    final severity = event['severity']?.toString() ?? '';
    final outcome = event['outcome']?.toString() ?? '';
    return severity == 'error' || outcome == 'failure' || outcome == 'denied';
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    _isReloading = true;
    setState(() => _isLoading = true);
    final client = context.read<JsonRpcRiftClient>();

    try {
      if (!client.isConnected) {
        try {
          await client.connect();
        } catch (_) {}
      }

      if (!client.isConnected) {
        if (mounted && generation == _loadGeneration) {
          setState(() {
            _error = 'Daemon not connected.';
            _isLoading = false;
          });
        }
        return;
      }

      final peersResult = await client.listTrustedPeers();
      final discoveredResult = await client.listDiscoveredPeers();
      final eventsResult = await client.queryEventLog(limit: 3);

      final peers = List<Map<String, dynamic>>.from(
        (peersResult['peers'] as List? ?? const <dynamic>[])
            .map((e) => Map<String, dynamic>.from(e as Map)),
      );

      final discovered = List<Map<String, dynamic>>.from(
        (discoveredResult['peers'] as List? ?? const <dynamic>[])
            .map((e) => Map<String, dynamic>.from(e as Map)),
      );

      final events = List<Map<String, dynamic>>.from(
        (eventsResult['events'] as List? ?? const <dynamic>[])
            .map((e) => Map<String, dynamic>.from(e as Map)),
      );

      int trusted = 0;
      int blocked = 0;
      int pending = 0;

      for (final p in peers) {
        final state = p['trustState']?.toString() ?? 'unknown';
        if (state == 'trusted') {
          trusted++;
        } else if (state == 'blocked') {
          blocked++;
        } else if (state == 'pairing_pending') {
          pending++;
        }
      }

      Map<String, dynamic>? alert;
      for (final ev in events) {
        if (_isSecurityEvent(ev) && _isErrorEvent(ev)) {
          alert = ev;
          break;
        }
      }

      if (mounted && generation == _loadGeneration) {
        setState(() {
          _trustedCount = trusted;
          _blockedCount = blocked;
          _pendingCount = pending;
          _discoveredCount = discovered.length;
          _trustedPeers = peers;
          _discoveredPeers = discovered;
          _recentEvents = events;
          _criticalAlert = alert;
          _isLoading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = JsonRpcRiftClient.formatDisplayError(e);
          _isLoading = false;
        });
      }
    } finally {
      _isReloading = false;
      if (_reloadQueued) {
        _reloadQueued = false;
        if (mounted) {
          _loadData();
        }
      }
    }
  }

  String _formatTimeOnly(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return 'Unknown';
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } catch (_) {
      return timestamp;
    }
  }

  String _peerDisplayName(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return 'Unknown device';
    for (final peer in _trustedPeers) {
      if (peer['deviceId']?.toString() == deviceId) {
        final name = peer['displayName']?.toString().trim();
        if (name != null && name.isNotEmpty) return name;
      }
    }
    for (final peer in _discoveredPeers) {
      if (peer['deviceId']?.toString() == deviceId) {
        final name = peer['displayName']?.toString().trim();
        if (name != null && name.isNotEmpty) return name;
      }
    }
    if (deviceId.length > 12) {
      return '${deviceId.substring(0, 8)}…${deviceId.substring(deviceId.length - 4)}';
    }
    return deviceId;
  }

  String _formatEventTypeLabel(String eventType) {
    switch (eventType.toLowerCase()) {
      case 'trust.transitioned':
        return 'Pairing completed';
      case 'auth.failed':
        return 'Authentication failed';
      case 'peer.discovered':
        return 'Device discovered';
      case 'peer.lost':
        return 'Device lost';
      default:
        return eventType;
    }
  }

  Widget _buildStatCard({
    required String label,
    required int count,
    required Color labelColor,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final cardContent = Container(
      padding: RiftDesign.padCard,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count.toString(),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: labelColor,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return cardContent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: theme.colorScheme.primary.withValues(alpha: 0.04),
        child: cardContent,
      ),
    );
  }

  Widget _buildStatsGrid(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cards = [
          _buildStatCard(
            label: 'TRUSTED',
            count: _trustedCount,
            labelColor: theme.colorScheme.primary,
          ),
          _buildStatCard(
            label: 'BLOCKED',
            count: _blockedCount,
            labelColor: theme.colorScheme.error,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BlockedPeersScreen()),
              );
            },
          ),
          _buildStatCard(
            label: 'PENDING',
            count: _pendingCount,
            labelColor: theme.colorScheme.tertiary,
          ),
          _buildStatCard(
            label: 'DISCOVERED',
            count: _discoveredCount,
            labelColor: theme.colorScheme.secondary,
          ),
        ];

        if (constraints.maxWidth <= 550) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: cards[2]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[3]),
                ],
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 12),
            Expanded(child: cards[1]),
            const SizedBox(width: 12),
            Expanded(child: cards[2]),
            const SizedBox(width: 12),
            Expanded(child: cards[3]),
          ],
        );
      },
    );
  }

  Widget _buildEventRow(Map<String, dynamic> event) {
    final theme = Theme.of(context);
    final eventType = event['eventType']?.toString() ?? 'unknown';
    final timestamp = _formatTimeOnly(event['timestamp']?.toString());
    final peerId = event['peerDeviceId']?.toString();
    final peerName = _peerDisplayName(peerId);
    final reason = event['failureReason']?.toString();
    final outcome = event['outcome']?.toString() ?? '';

    final isError = _isErrorEvent(event);
    final isSecurity = _isSecurityEvent(event);

    Color dotColor;
    String title;
    String subtitle;

    if (isError) {
      dotColor = theme.colorScheme.error;
      title = isSecurity ? 'Security Event: $peerName' : 'Error: $eventType';
      subtitle = reason != null && reason.isNotEmpty
          ? 'Failure — $reason'
          : 'Outcome: ${outcome.isNotEmpty ? outcome : "failed"}';
    } else if (isSecurity) {
      dotColor = const Color(0xFF10B981);
      title = eventType.startsWith('auth')
          ? 'Auth Event: $peerName'
          : 'Trust Updated: $peerName';
      subtitle = reason != null && reason.isNotEmpty
          ? reason
          : '${_formatEventTypeLabel(eventType)} — trust state: ${event['trustState'] ?? "trusted"}';
    } else {
      dotColor = theme.colorScheme.outlineVariant;
      title = eventType;
      subtitle = peerId != null && peerId.isNotEmpty
          ? '$peerName — local network'
          : 'System event — $outcome';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(
            timestamp,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    final screenPadding =
        isDesktop ? RiftDesign.padScreenDesktop : RiftDesign.padScreenMobile;
    final isConnected = _error == null;
    final statusColor =
        isConnected ? theme.colorScheme.primary : theme.colorScheme.error;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: _isLoading && _trustedCount == 0 && _recentEvents.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: screenPadding,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Security',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurface,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: statusColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              isConnected ? 'Connected' : 'Disconnected',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: RiftDesign.spaceMd),
                  _buildStatsGrid(theme),
                  const SizedBox(height: RiftDesign.spaceXl),
                  if (_criticalAlert != null) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: RiftDesign.spaceLg),
                      padding: RiftDesign.padCard,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.error.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 24, color: theme.colorScheme.error),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              '${_criticalAlert!['eventType'] ?? 'alert'} from ${_peerDisplayName(_criticalAlert!['peerDeviceId']?.toString())} — ${_criticalAlert!['failureReason'] ?? 'Security incident detected'}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            icon: Icon(Icons.close,
                                color: theme.colorScheme.onErrorContainer),
                            onPressed: () =>
                                setState(() => _criticalAlert = null),
                            tooltip: 'Dismiss alert',
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: RiftDesign.spaceLg),
                      padding: RiftDesign.padCard,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.error.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 24, color: theme.colorScheme.error),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              _error!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Recent Events',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${_recentEvents.length} Events',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_recentEvents.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 64, horizontal: 24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: theme.colorScheme.outlineVariant),
                      ),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.event_busy,
                              size: 48,
                              color: theme.colorScheme.outlineVariant),
                          const SizedBox(height: 16),
                          Text(
                            'No recent events',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Column(
                        children: [
                          for (int i = 0; i < _recentEvents.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                thickness: 1,
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.5),
                              ),
                            _buildEventRow(_recentEvents[i]),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (navContext) => EventLogScreen(
                              onBack: () => Navigator.of(navContext).pop(),
                            ),
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4)),
                        side:
                            BorderSide(color: theme.colorScheme.outlineVariant),
                      ),
                      child: Text(
                        'VIEW FULL LOG',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
