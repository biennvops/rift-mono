import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';
import 'event_log_screen.dart';
import 'dart:async';

class SecurityDashboardScreen extends StatefulWidget {
  const SecurityDashboardScreen({super.key});

  @override
  State<SecurityDashboardScreen> createState() => _SecurityDashboardScreenState();
}

class _SecurityDashboardScreenState extends State<SecurityDashboardScreen> {
  bool _isLoading = true;
  String? _error;
  
  int _trustedCount = 0;
  int _blockedCount = 0;
  int _revokedCount = 0;
  int _discoveredCount = 0;
  
  List<Map<String, dynamic>> _recentEvents = [];
  Map<String, dynamic>? _criticalAlert;
  
  StreamSubscription<Map<String, dynamic>>? _securitySub;
  StreamSubscription<Map<String, dynamic>>? _trustSub;
  StreamSubscription<Map<String, dynamic>>? _peerDiscoveredSub;
  StreamSubscription<Map<String, dynamic>>? _peerLostSub;
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
    return severity == 'error' ||
        outcome == 'failure' ||
        outcome == 'denied';
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    _isReloading = true;
    setState(() => _isLoading = true);
    final client = context.read<JsonRpcRiftClient>();
    
    try {
      final peersResult = await client.listTrustedPeers();
      final discoveredResult = await client.listDiscoveredPeers();
      final eventsResult = await client.queryEventLog(limit: 3);
      
      final peers = List<Map<String, dynamic>>.from(
        (peersResult['peers'] as List? ?? const <dynamic>[]).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      
      final discovered = List<Map<String, dynamic>>.from(
        (discoveredResult['peers'] as List? ?? const <dynamic>[]).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      
      final events = List<Map<String, dynamic>>.from(
        (eventsResult['events'] as List? ?? const <dynamic>[]).map((e) => Map<String, dynamic>.from(e as Map)),
      );

      int trusted = 0;
      int blocked = 0;
      int revoked = 0;
      
      for (final p in peers) {
        final state = p['trustState']?.toString() ?? 'unknown';
        if (state == 'trusted') {
          trusted++;
        } else if (state == 'blocked') {
          blocked++;
        } else if (state == 'revoked') {
          revoked++;
        }
      }
      
      // Look for a critical alert in recent events (e.g. auth.failed with critical severity)
      // If none, we leave it null.
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
          _revokedCount = revoked;
          _discoveredCount = discovered.length;
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

  Widget _buildBentoCard({
    required BuildContext context,
    required String label,
    required IconData icon,
    required int count,
    required Color color,
    required Color labelColor,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontFamily: 'JetBrains Mono',
                  letterSpacing: 1.0,
                  color: labelColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Icon(icon, color: color, size: 20),
            ],
          ),
          const Spacer(),
          Text(
            count.toString(),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventItem(Map<String, dynamic> event) {
    final theme = Theme.of(context);
    final eventType = event['eventType']?.toString() ?? 'unknown';
    final timestamp = _formatTimeOnly(event['timestamp']?.toString());
    final peer = event['peerDeviceId']?.toString() ?? 'unknown';
    final reason = event['failureReason']?.toString();

    Color color = theme.colorScheme.outline;
    Color bgColor = theme.colorScheme.surfaceContainerHighest;
    IconData icon = Icons.info;
    String title = eventType;
    String subtitle = 'Device: $peer';

    if (_isErrorEvent(event)) {
      color = theme.colorScheme.onErrorContainer;
      bgColor = theme.colorScheme.errorContainer;
      icon = _isSecurityEvent(event) ? Icons.gpp_bad : Icons.error_outline;
      title = _isSecurityEvent(event) ? 'Security Event: $peer' : 'Error: $eventType';
      if (reason != null) subtitle = reason;
    } else if (_isSecurityEvent(event)) {
      color = theme.colorScheme.onSecondaryContainer;
      bgColor = theme.colorScheme.secondaryContainer;
      icon = Icons.gpp_good;
      title = eventType.startsWith('auth') ? 'Auth Event: $peer' : 'Trust Updated: $peer';
      if (reason != null) subtitle = reason;
    } else {
      color = theme.colorScheme.onSurfaceVariant;
      bgColor = theme.colorScheme.surfaceContainerHighest;
      icon = Icons.sync;
      title = eventType;
      if (reason != null) subtitle = reason;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timestamp,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'JetBrains Mono',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontFamily: 'JetBrains Mono',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: _isLoading && _trustedCount == 0 && _recentEvents.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 100),
                children: [
                  Text(
                    'Security',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'System status and recent operations.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  if (_criticalAlert != null) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: theme.colorScheme.onErrorContainer),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning, color: theme.colorScheme.onError),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'CRITICAL: ${_criticalAlert!['eventType']}',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: theme.colorScheme.onError,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _criticalAlert!['failureReason']?.toString() ?? 'Security incident detected',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onError.withAlpha(230),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    ElevatedButton(
                                      onPressed: () {
                                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EventLogScreen()));
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: theme.colorScheme.onError,
                                        foregroundColor: theme.colorScheme.error,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      ),
                                      child: const Text('REVIEW LOGS', style: TextStyle(fontFamily: 'JetBrains Mono', fontSize: 12, fontWeight: FontWeight.w600)),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton(
                                      onPressed: () {
                                        setState(() => _criticalAlert = null);
                                      },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: theme.colorScheme.onError,
                                        side: BorderSide(color: theme.colorScheme.onError),
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      ),
                                      child: const Text('DISMISS', style: TextStyle(fontFamily: 'JetBrains Mono', fontSize: 12, fontWeight: FontWeight.w600)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      color: theme.colorScheme.errorContainer,
                      child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                    ),
                    const SizedBox(height: 24),
                  ],

                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 1.5,
                    children: [
                      _buildBentoCard(
                        context: context,
                        label: 'TRUSTED',
                        icon: Icons.check_circle,
                        count: _trustedCount,
                        color: theme.colorScheme.secondary,
                        labelColor: theme.colorScheme.secondary,
                      ),
                      _buildBentoCard(
                        context: context,
                        label: 'BLOCKED',
                        icon: Icons.block,
                        count: _blockedCount,
                        color: theme.colorScheme.error,
                        labelColor: theme.colorScheme.error,
                      ),
                      _buildBentoCard(
                        context: context,
                        label: 'REVOKED',
                        icon: Icons.history_toggle_off,
                        count: _revokedCount,
                        color: theme.colorScheme.onSurfaceVariant,
                        labelColor: theme.colorScheme.onSurfaceVariant,
                      ),
                      _buildBentoCard(
                        context: context,
                        label: 'DISCOVERED',
                        icon: Icons.wifi_tethering,
                        count: _discoveredCount,
                        color: theme.colorScheme.primary,
                        labelColor: theme.colorScheme.primary,
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),
                  Text(
                    'Recent Events',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  if (_recentEvents.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Text(
                          'No recent events',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  else
                    ..._recentEvents.map((e) => _buildEventItem(e)),

                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EventLogScreen()));
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      side: BorderSide(color: theme.colorScheme.primary),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('VIEW FULL LOG', style: TextStyle(fontFamily: 'JetBrains Mono', letterSpacing: 1.0, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
      ),
    );
  }
}
