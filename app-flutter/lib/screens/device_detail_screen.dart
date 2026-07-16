import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';

class DeviceDetailScreen extends StatefulWidget {
  final Map<String, dynamic> peer;
  final bool isOnline;

  const DeviceDetailScreen({
    super.key,
    required this.peer,
    required this.isOnline,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  late Map<String, dynamic> peer;
  late bool isOnline;
  late final String _deviceId;
  bool _wasRemoved = false;
  bool _isRefreshing = false;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<Map<String, dynamic>>? _peerLostSub;
  StreamSubscription<bool>? _connectionChangedSub;

  @override
  void initState() {
    super.initState();
    peer = widget.peer;
    isOnline = widget.isOnline;
    _deviceId = widget.peer['deviceId']?.toString() ?? '';
    _subscribeToPeerUpdates();
  }

  @override
  void dispose() {
    _trustChangedSub?.cancel();
    _peerLostSub?.cancel();
    _connectionChangedSub?.cancel();
    super.dispose();
  }

  void _subscribeToPeerUpdates() {
    final client = context.read<JsonRpcRiftClient>();
    _trustChangedSub = client.onTrustChanged.listen(_handleTrustChanged);
    _peerLostSub = client.onPeerLost.listen(_handlePeerLost);
    _connectionChangedSub = client.onConnectionChanged.listen((isConnected) {
      if (!mounted) return;
      if (isConnected) {
        unawaited(_refreshPeerFromDaemon());
      }
    });
  }

  void _handleTrustChanged(Map<String, dynamic> event) {
    final eventDeviceId = event['deviceId']?.toString();
    if (eventDeviceId == null || eventDeviceId != _deviceId) {
      return;
    }

    final newState = event['newState']?.toString();
    if (newState == 'trusted') {
      unawaited(_refreshPeerFromDaemon());
      return;
    }

    if (!mounted) return;
    setState(() {
      _wasRemoved = true;
      isOnline = false;
      if (newState != null && newState.isNotEmpty) {
        peer = Map<String, dynamic>.from(peer)..['trustState'] = newState;
      }
    });
  }

  void _handlePeerLost(Map<String, dynamic> event) {
    final eventDeviceId = event['deviceId']?.toString();
    if (eventDeviceId == null || eventDeviceId != _deviceId || !mounted) {
      return;
    }
    setState(() {
      isOnline = false;
    });
  }

  Future<void> _refreshPeerFromDaemon() async {
    if (!mounted || _deviceId.isEmpty || _isRefreshing) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      return;
    }

    _isRefreshing = true;
    try {
      final result = await client.listTrustedPeers();
      final peers = List<dynamic>.from((result as Map)['peers'] ?? const []);
      Map<String, dynamic>? refreshedPeer;
      for (final candidate in peers) {
        if (candidate is! Map) continue;
        final map = Map<String, dynamic>.from(candidate);
        if (map['deviceId']?.toString() == _deviceId) {
          refreshedPeer = map;
          break;
        }
      }

      if (!mounted) return;
      if (refreshedPeer == null) {
        setState(() {
          _wasRemoved = true;
          isOnline = false;
        });
        return;
      }

      setState(() {
        peer = refreshedPeer!;
        isOnline = refreshedPeer['presence']?.toString() == 'online';
        _wasRemoved = false;
      });
    } catch (_) {
      // Keep the last known snapshot if a transient refresh fails.
    } finally {
      _isRefreshing = false;
    }
  }

  String _formatFingerprintWithColons(String? fp) {
    if (fp == null) return 'WAITING...';
    final clean = fp.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.isEmpty) return fp;
    final chunks = <String>[];
    for (int i = 0; i < clean.length; i += 2) {
      chunks.add(
        clean.substring(i, (i + 2) > clean.length ? clean.length : i + 2),
      );
    }
    return chunks.join(':');
  }

  String _formatTimestamp(String? raw) {
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

  IconData _platformIcon(String? platform) {
    switch (platform?.toLowerCase()) {
      case 'android':
      case 'ios':
        return Icons.smartphone;
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }

  Future<bool> _showForgetBottomSheet(
    String displayName,
    String fingerprint,
  ) async {
    final theme = Theme.of(context);
    final shortFingerprint = fingerprint.length > 16
        ? '${fingerprint.substring(0, 16)}...'
        : fingerprint;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).padding.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 6,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Icon(Icons.warning, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Quên thiết bị $displayName?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Thiết bị sẽ bị xóa khỏi danh sách đã tin cậy trên máy này. Khi thấy lại nó trong danh sách khám phá, bạn có thể pair lại từ đầu.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Icon(Icons.fingerprint, color: theme.colorScheme.outline),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TARGET KEY',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          shortFingerprint,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text(
                    'Quên thiết bị',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurface,
                    side: BorderSide(color: theme.colorScheme.outline),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Hủy',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    return result ?? false;
  }

  Future<bool> _showBlockBottomSheet(String displayName) async {
    final theme = Theme.of(context);

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).padding.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.block,
                  color: theme.colorScheme.error,
                  size: 24,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Chặn $displayName?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Thiết bị bị chặn vĩnh viễn. Mọi kết nối từ khóa Ed25519 này sẽ bị từ chối tự động.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    'Chặn vĩnh viễn',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(color: theme.colorScheme.outline),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    'Hủy',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    return result ?? false;
  }

  Future<void> _forgetPeer() async {
    final deviceId = peer['deviceId']?.toString();
    final displayName =
        peer['displayName']?.toString() ?? deviceId ?? 'Unknown';
    final fingerprint = peer['fingerprint']?.toString() ?? 'Unknown';
    if (deviceId == null) return;
    final client = context.read<JsonRpcRiftClient>();

    final confirmed = await _showForgetBottomSheet(displayName, fingerprint);
    if (!confirmed) return;

    try {
      await client.revokeTrust(
        deviceId,
        'User removed trusted device from Device Detail',
      );
      if (!mounted) return;
      Navigator.of(context).pop({
        'action': 'forgotten',
        'deviceId': deviceId,
        'displayName': displayName,
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _blockPeer() async {
    final deviceId = peer['deviceId']?.toString();
    final displayName =
        peer['displayName']?.toString() ?? deviceId ?? 'Unknown';
    if (deviceId == null) return;

    final confirmed = await _showBlockBottomSheet(displayName);
    if (!confirmed || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Block not implemented in daemon yet')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceId = peer['deviceId']?.toString() ?? 'Unknown ID';
    final displayName = peer['displayName']?.toString() ?? deviceId;
    final fingerprint = peer['fingerprint']?.toString() ?? '';
    final trustState = peer['trustState']?.toString() ?? 'trusted';
    final implementationId =
        peer['implementationId']?.toString() ?? 'Unavailable';
    final protocolVersion =
        peer['protocolVersion']?.toString() ?? 'Unavailable';
    final platform = peer['platform']?.toString();
    final ipAddress = peer['lastAddress']?.toString() ??
        peer['address']?.toString() ??
        'Unavailable';
    final tlsCipher = peer['tlsCipher']?.toString() ?? 'Unavailable';
    final latency =
        peer['latencyMs'] != null ? '${peer['latencyMs']} ms' : 'Unavailable';
    final pairedAt = _formatTimestamp(peer['pairedAt']?.toString());
    final lastSeenAt = _formatTimestamp(peer['lastSeenAt']?.toString());
    final capabilities = List<String>.from(
      (peer['capabilities'] as List? ?? const <dynamic>[]).map(
        (item) => item.toString(),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _wasRemoved ? 'Device unavailable' : displayName,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: theme.colorScheme.outlineVariant, height: 1),
        ),
      ),
      body: _wasRemoved
          ? _buildRemovedState(theme, displayName)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: theme.colorScheme.outlineVariant),
                        ),
                        child: Icon(
                          _platformIcon(platform),
                          size: 32,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.verified,
                                  size: 14,
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  trustState.toUpperCase(),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: isOnline
                                      ? theme.colorScheme.secondary
                                      : theme.colorScheme.outline,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isOnline ? 'ONLINE' : 'OFFLINE',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: isOnline
                                      ? theme.colorScheme.secondary
                                      : theme.colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        trustState == 'trusted'
                            ? 'Trusted since $pairedAt'
                            : 'Last seen $lastSeenAt',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _buildSection(
                  theme,
                  'IDENTITY',
                  [
                    _buildInfoLine(theme, 'Device ID', deviceId),
                    const SizedBox(height: 12),
                    Text(
                      'Fingerprint',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _formatFingerprintWithColons(fingerprint),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildInfoColumn(
                            theme,
                            'Certificate',
                            implementationId,
                          ),
                        ),
                        Expanded(
                          child: _buildInfoColumn(
                            theme,
                            'Protocol',
                            protocolVersion,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSection(
                  theme,
                  'SESSION & CAPABILITIES',
                  [
                    Row(
                      children: [
                        Expanded(
                          child: _buildInfoColumn(
                            theme,
                            'Platform',
                            platform?.toUpperCase() ?? 'Unavailable',
                          ),
                        ),
                        Expanded(
                          child:
                              _buildInfoColumn(theme, 'IP Address', ipAddress),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildInfoColumn(theme, 'Latency', latency),
                        ),
                        Expanded(
                          child:
                              _buildInfoColumn(theme, 'TLS Cipher', tlsCipher),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant
                          .withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Capabilities',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: capabilities.isEmpty
                          ? [
                              Text(
                                'Unavailable',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ]
                          : capabilities.map((capability) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: theme.colorScheme.outlineVariant,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  capability,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              );
                            }).toList(growable: false),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                OutlinedButton(
                  onPressed: _forgetPeer,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Quên thiết bị',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _blockPeer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Chặn',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Blocking from this view is pending full daemon support.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildRemovedState(ThemeData theme, String displayName) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.device_unknown,
                size: 36,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '$displayName is no longer available',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This trusted device was removed or is no longer in your trusted list. Return to the home screen to continue.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop({
                    'action': 'removed',
                    'deviceId': _deviceId,
                    'displayName': displayName,
                  });
                },
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to home'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(ThemeData theme, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoLine(ThemeData theme, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoColumn(ThemeData theme, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
