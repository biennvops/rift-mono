import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';
import 'dart:async';

class BlockedPeersScreen extends StatefulWidget {
  const BlockedPeersScreen({super.key});

  @override
  State<BlockedPeersScreen> createState() => _BlockedPeersScreenState();
}

class _BlockedPeersScreenState extends State<BlockedPeersScreen> {
  bool _isLoading = true;
  String? _error;
  List<Map<String, dynamic>> _blockedPeers = [];
  StreamSubscription<Map<String, dynamic>>? _trustSub;
  final Set<String> _unblockingPeers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      final client = context.read<JsonRpcRiftClient>();
      _trustSub = client.onTrustChanged.listen((event) {
        if (!mounted) return;
        _loadData();
      });
    });
  }

  @override
  void dispose() {
    _trustSub?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final client = context.read<JsonRpcRiftClient>();

    try {
      if (!client.isConnected) {
        await client.connect();
      }
      if (!client.isConnected) {
        if (mounted) {
          setState(() {
            _error = 'Daemon not connected.';
            _isLoading = false;
          });
        }
        return;
      }

      final peersResult = await client.listTrustedPeers();
      final peers = List<Map<String, dynamic>>.from(
        (peersResult['peers'] as List? ?? const <dynamic>[])
            .map((e) => Map<String, dynamic>.from(e as Map)),
      );

      final blocked = peers.where((p) => p['trustState'] == 'blocked').toList();

      if (mounted) {
        setState(() {
          _blockedPeers = blocked;
          _isLoading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = JsonRpcRiftClient.formatDisplayError(e);
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _unblockPeer(String deviceId) async {
    setState(() {
      _unblockingPeers.add(deviceId);
    });

    final client = context.read<JsonRpcRiftClient>();
    try {
      // Unblock functionality in daemon.
      await client.unblockPeer(deviceId);

      if (mounted) {
        setState(() {
          _blockedPeers.removeWhere((p) => p['deviceId'] == deviceId);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Failed to unblock: ${JsonRpcRiftClient.formatDisplayError(e)}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _unblockingPeers.remove(deviceId);
        });
      }
    }
  }

  Future<bool> _showUnblockConfirmation(String displayName) async {
    final theme = Theme.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00327D).withValues(alpha: 0.1),
                  blurRadius: 40,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  child: Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer
                            .withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.lock_open,
                        color: theme.colorScheme.primary,
                        size: 32,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    children: [
                      Text(
                        'Unblock $displayName?',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This device will be able to see your local presence again.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border(
                        top: BorderSide(
                            color: theme.colorScheme.outlineVariant)),
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(12)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                          side: BorderSide(color: theme.colorScheme.primary),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                        ),
                        child: const Text('Cancel',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                      const SizedBox(width: 16),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                        ),
                        child: const Text('Unblock',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return result ?? false;
  }

  IconData _platformIcon(String? platform) {
    if (platform == null) return Icons.device_unknown;
    final p = platform.toLowerCase();
    if (p.contains('android')) return Icons.smartphone;
    if (p.contains('windows')) return Icons.desktop_windows;
    if (p.contains('mac') || p.contains('ios')) {
      return Icons.laptop_mac; // approximate for iOS/Mac
    }
    if (p.contains('linux')) return Icons.computer;
    return Icons.devices;
  }

  String _formatDate(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return 'Unknown Date';
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      return '${months[dt.month - 1]} ${dt.day.toString().padLeft(2, '0')}, ${dt.year}';
    } catch (_) {
      return timestamp;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        title: Text(
          'Blocked Peers',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: theme.colorScheme.outlineVariant, height: 1),
        ),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Text(_error!,
                      style: TextStyle(color: theme.colorScheme.error)),
                )
              : SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: 1024), // max-w-5xl
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Text(
                              'Manage devices that have been restricted from connecting to your secure sync network. Unblocking a device will restore its ability to request connection.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.secondary),
                            ),
                          ),
                          if (_blockedPeers.isEmpty)
                            Center(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 48),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 64,
                                      height: 64,
                                      decoration: BoxDecoration(
                                        color:
                                            theme.colorScheme.surfaceContainer,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(Icons.verified_user,
                                          size: 32,
                                          color: theme.colorScheme.secondary),
                                    ),
                                    const SizedBox(height: 16),
                                    Text('No Blocked Peers',
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                                color:
                                                    theme.colorScheme.onSurface,
                                                fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 8),
                                    Text('You haven\'t blocked any devices.',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                                color: theme
                                                    .colorScheme.secondary)),
                                  ],
                                ),
                              ),
                            )
                          else
                            Container(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerLowest,
                                border: Border.all(
                                    color: theme.colorScheme.outlineVariant),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                children: [
                                  // List Header
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.surfaceContainer,
                                      border: Border(
                                          bottom: BorderSide(
                                              color: theme
                                                  .colorScheme.outlineVariant)),
                                      borderRadius: const BorderRadius.vertical(
                                          top: Radius.circular(12)),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          flex: 2,
                                          child: Text('DEVICE & PLATFORM',
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                      color: theme.colorScheme
                                                          .secondary,
                                                      letterSpacing: 1.0)),
                                        ),
                                        if (!isMobile)
                                          Expanded(
                                            flex: 1,
                                            child: Text('DATE BLOCKED',
                                                style: theme
                                                    .textTheme.labelSmall
                                                    ?.copyWith(
                                                        color: theme.colorScheme
                                                            .secondary,
                                                        letterSpacing: 1.0)),
                                          ),
                                        Text('ACTION',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                    color: theme
                                                        .colorScheme.secondary,
                                                    letterSpacing: 1.0)),
                                      ],
                                    ),
                                  ),
                                  ..._blockedPeers.asMap().entries.map((entry) {
                                    final index = entry.key;
                                    final peer = entry.value;
                                    final isLast =
                                        index == _blockedPeers.length - 1;
                                    final deviceId =
                                        peer['deviceId']?.toString() ??
                                            'unknown';
                                    final displayName =
                                        peer['displayName']?.toString() ??
                                            'Unknown Device';
                                    final platform =
                                        peer['platform']?.toString();
                                    final osVersion =
                                        peer['osVersion']?.toString() ??
                                            'Unknown OS';
                                    final blockedAt = _formatDate(
                                        peer['blockedAt']?.toString() ??
                                            peer['lastSeenAt']?.toString());
                                    final isUnblocking =
                                        _unblockingPeers.contains(deviceId);

                                    return Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        border: isLast
                                            ? null
                                            : Border(
                                                bottom: BorderSide(
                                                    color: theme.colorScheme
                                                        .outlineVariant)),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 40,
                                                  height: 40,
                                                  decoration: BoxDecoration(
                                                    color: theme.colorScheme
                                                        .errorContainer,
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: Icon(
                                                      _platformIcon(platform),
                                                      color: theme
                                                          .colorScheme.error,
                                                      size: 20),
                                                ),
                                                const SizedBox(width: 16),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        displayName,
                                                        style: theme.textTheme
                                                            .labelMedium
                                                            ?.copyWith(
                                                          color: theme
                                                              .colorScheme
                                                              .onSurface,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      const SizedBox(height: 4),
                                                      if (isMobile) ...[
                                                        Text(
                                                          'Blocked: $blockedAt',
                                                          style: theme.textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                  color: theme
                                                                      .colorScheme
                                                                      .secondary),
                                                        ),
                                                      ] else ...[
                                                        Row(
                                                          children: [
                                                            Icon(
                                                                _platformIcon(
                                                                    platform),
                                                                size: 14,
                                                                color: theme
                                                                    .colorScheme
                                                                    .secondary),
                                                            const SizedBox(
                                                                width: 4),
                                                            Text(
                                                              '${platform != null ? platform.toUpperCase() : "UNKNOWN"} $osVersion',
                                                              style: theme
                                                                  .textTheme
                                                                  .bodySmall
                                                                  ?.copyWith(
                                                                      color: theme
                                                                          .colorScheme
                                                                          .secondary),
                                                            ),
                                                          ],
                                                        ),
                                                      ]
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (!isMobile)
                                            Expanded(
                                              flex: 1,
                                              child: Text(
                                                blockedAt,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                        color: theme.colorScheme
                                                            .secondary),
                                              ),
                                            ),
                                          OutlinedButton(
                                            onPressed: isUnblocking
                                                ? null
                                                : () async {
                                                    final confirmed =
                                                        await _showUnblockConfirmation(
                                                            displayName);
                                                    if (confirmed) {
                                                      _unblockPeer(deviceId);
                                                    }
                                                  },
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor:
                                                  theme.colorScheme.primary,
                                              side: BorderSide(
                                                  color: theme
                                                      .colorScheme.primary),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 8),
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(4)),
                                            ),
                                            child: isUnblocking
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                            strokeWidth: 2))
                                                : const Text('Unblock',
                                                    style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 14)),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}
