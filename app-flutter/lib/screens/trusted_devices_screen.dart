import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../src/ipc/json_rpc_client.dart';
import 'pairing_screen.dart';

class TrustedDevicesScreen extends StatefulWidget {
  const TrustedDevicesScreen({super.key});

  @override
  State<TrustedDevicesScreen> createState() => _TrustedDevicesScreenState();
}

class _TrustedDevicesScreenState extends State<TrustedDevicesScreen> {
  static const Duration _presenceRefreshInterval = Duration(seconds: 5);

  bool _isDiscovering = false;
  List<dynamic> _trustedPeers = [];
  List<dynamic> _discoveredPeers = [];
  String? _error;
  bool _isLoadingData = false;
  bool _reloadQueued = false;

  StreamSubscription? _discoverySub;
  StreamSubscription? _peerLostSub;
  StreamSubscription? _trustSub;
  StreamSubscription? _pairingCompleteSub;
  Timer? _reloadDebounce;
  Timer? _fullReloadThrottle;
  Timer? _presenceRefreshTimer;

  @override
  void initState() {
    super.initState();
    // Schedule fetch after layout to ensure Provider is accessible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      _setupListeners();
    });
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _fullReloadThrottle?.cancel();
    _presenceRefreshTimer?.cancel();
    _discoverySub?.cancel();
    _peerLostSub?.cancel();
    _trustSub?.cancel();
    _pairingCompleteSub?.cancel();
    super.dispose();
  }

  void _setupListeners() {
    final client = context.read<JsonRpcRiftClient>();
    _discoverySub = client.onPeerDiscovered.listen(_handlePeerDiscovered);
    _peerLostSub = client.onPeerLost.listen(_handlePeerLost);
    _trustSub = client.onTrustChanged.listen(_handleTrustChanged);
    _pairingCompleteSub =
        client.onPairingComplete.listen(_handlePairingComplete);
  }

  void _scheduleReload() {
    if (!mounted) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 250), () {
      _loadData();
    });
  }

  void _scheduleFullReloadThrottled() {
    if (!mounted) return;
    // Coalesce noisy event bursts into at most 1 full reload per 2 seconds.
    if (_fullReloadThrottle != null) return;
    _fullReloadThrottle = Timer(const Duration(seconds: 2), () {
      _fullReloadThrottle = null;
    });
    _scheduleReload();
  }

  void _handlePeerDiscovered(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;
    if (!mounted) return;
    if (_isPeerAlreadyManaged(deviceId)) return;

    setState(() {
      // Upsert into discovered list.
      final existing = _discoveredPeers
          .indexWhere((p) => p is Map && p['deviceId']?.toString() == deviceId);
      if (existing >= 0) {
        final merged =
            Map<String, dynamic>.from(_discoveredPeers[existing] as Map);
        merged.addAll(event);
        _discoveredPeers[existing] = merged;
      } else {
        _discoveredPeers = [event, ..._discoveredPeers];
      }
    });

    // Full reload is still needed to pick up trust state/capabilities accurately.
    _scheduleFullReloadThrottled();
  }

  void _handlePeerLost(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;
    if (!mounted) return;

    setState(() {
      _discoveredPeers = _discoveredPeers
          .where((p) => !(p is Map && p['deviceId']?.toString() == deviceId))
          .toList(growable: false);
    });

    _scheduleFullReloadThrottled();
  }

  void _handleTrustChanged(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString();
    final newState = event['newState']?.toString();
    if (deviceId == null ||
        deviceId.isEmpty ||
        newState == null ||
        newState.isEmpty) {
      return;
    }
    if (!mounted) return;

    final reason = event['reason']?.toString();
    final previous = event['previousState']?.toString();

    // Quick UI feedback for state transitions (helps triage).
    if (reason != null && reason.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Trust changed: $newState${previous != null ? ' (from $previous)' : ''} - $reason')),
      );
    }

    // We can't fully materialize trusted peer details from the event alone,
    // so do a throttled full reload. Still, update minimal local state to
    // prevent the UI from feeling stale.
    setState(() {
      // Remove from discovered if it is no longer discovered/pairing_pending.
      if (newState == 'trusted' ||
          newState == 'blocked' ||
          newState == 'revoked') {
        _discoveredPeers = _discoveredPeers
            .where((p) => !(p is Map && p['deviceId']?.toString() == deviceId))
            .toList(growable: false);
      }
    });

    _scheduleFullReloadThrottled();
  }

  void _handlePairingComplete(Map<String, dynamic> event) {
    // Spec: includes persistedAt, but listTrustedPeers is the source of truth.
    _scheduleFullReloadThrottled();
  }

  void _syncPresenceRefreshLoop() {
    final shouldRefresh = mounted && _trustedPeers.isNotEmpty;
    if (!shouldRefresh) {
      _presenceRefreshTimer?.cancel();
      _presenceRefreshTimer = null;
      return;
    }

    if (_presenceRefreshTimer != null) {
      return;
    }

    _presenceRefreshTimer = Timer.periodic(_presenceRefreshInterval, (_) {
      if (!mounted) return;
      final client = context.read<JsonRpcRiftClient>();
      if (!client.isConnected || _trustedPeers.isEmpty) {
        _syncPresenceRefreshLoop();
        return;
      }
      _loadData();
    });
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    if (_isLoadingData) {
      _reloadQueued = true;
      return;
    }

    _isLoadingData = true;
    final client = context.read<JsonRpcRiftClient>();

    // Default empty lists if not connected
    if (!client.isConnected) {
      setState(() {
        _trustedPeers = [];
        _discoveredPeers = [];
        _isDiscovering = false;
        _error = 'Daemon not connected';
      });
      _syncPresenceRefreshLoop();
      _isLoadingData = false;
      if (_reloadQueued) {
        _reloadQueued = false;
        _scheduleReload();
      }
      return;
    }

    try {
      final trustedResult = await client.listTrustedPeers();
      final discoveredResult = await client.listDiscoveredPeers();
      final trustedPeers =
          List<dynamic>.from(trustedResult['peers'] ?? const []);
      final discoveredPeers = _filterDiscoverablePeers(
        trustedPeers: trustedPeers,
        discoveredPeers: List<dynamic>.from(
          discoveredResult['peers'] ?? const [],
        ),
      );
      if (mounted) {
        setState(() {
          _trustedPeers = trustedPeers;
          _discoveredPeers = discoveredPeers;
          _isDiscovering = discoveredResult['isDiscovering'] == true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = JsonRpcRiftClient.formatDisplayError(e);
        });
      }
    } finally {
      _syncPresenceRefreshLoop();
      _isLoadingData = false;
      if (_reloadQueued) {
        _reloadQueued = false;
        _scheduleReload();
      }
    }
  }

  bool _isPeerAlreadyManaged(String deviceId) {
    return _trustedPeers.any(
      (peer) => peer is Map && peer['deviceId']?.toString() == deviceId,
    );
  }

  List<dynamic> _filterDiscoverablePeers({
    required List<dynamic> trustedPeers,
    required List<dynamic> discoveredPeers,
  }) {
    final trustedDeviceIds = trustedPeers
        .whereType<Map>()
        .map((peer) => peer['deviceId']?.toString())
        .whereType<String>()
        .where((deviceId) => deviceId.isNotEmpty)
        .toSet();

    const hiddenTrustStates = {
      'trusted',
      'blocked',
      'revoked',
      'pairing_pending',
    };

    return discoveredPeers.where((peer) {
      if (peer is! Map) return false;
      final deviceId = peer['deviceId']?.toString();
      if (deviceId == null || deviceId.isEmpty) return false;
      if (trustedDeviceIds.contains(deviceId)) return false;

      final trustState = peer['trustState']?.toString();
      if (trustState != null && hiddenTrustStates.contains(trustState)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  Future<void> _toggleDiscovery() async {
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) return;
    try {
      if (_isDiscovering) {
        await client.stopDiscovery();
      } else {
        await client.startDiscovery();
      }
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(JsonRpcRiftClient.formatDisplayError(e)),
          ),
        );
      }
    }
  }

  String _trustStateLabel(String trustState) {
    switch (trustState) {
      case 'pairing_pending':
        return 'Pairing pending';
      case 'blocked':
        return 'Blocked';
      case 'revoked':
        return 'Revoked';
      case 'trusted':
        return 'Trusted';
      default:
        return 'Discovered';
    }
  }

  IconData _trustedActionIcon(String trustState) {
    switch (trustState) {
      case 'blocked':
        return Icons.lock_open;
      case 'revoked':
        return Icons.restore;
      case 'pairing_pending':
        return Icons.close;
      default:
        return Icons.gpp_bad;
    }
  }

  String _trustedActionTooltip(String trustState) {
    switch (trustState) {
      case 'blocked':
        return 'Unblock device';
      case 'revoked':
        return 'Reset revoked peer';
      case 'pairing_pending':
        return 'Cancel pairing';
      default:
        return 'Revoke trust';
    }
  }

  Future<bool> _confirmTrustAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Widget _buildPeerCard(Map<String, dynamic> peer, bool isTrusted) {
    final isOnline = peer['presence'] == 'online';
    final trustState = peer['trustState']?.toString() ??
        (isTrusted ? 'trusted' : 'discovered');
    final trustLabel = _trustStateLabel(trustState);
    final theme = Theme.of(context);

    final String deviceIdStr = peer['deviceId']?.toString() ?? '';
    final String shortId =
        deviceIdStr.length > 16 ? deviceIdStr.substring(0, 16) : deviceIdStr;
    final String titleText = peer['displayName'] ??
        (deviceIdStr.isNotEmpty ? shortId : 'Unknown Device');

    return Card(
      elevation: 0,
      color: isTrusted
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isTrusted
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: isTrusted
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          foregroundColor: isTrusted
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurfaceVariant,
          child: Icon(
            isTrusted ? Icons.verified_user : Icons.device_unknown,
          ),
        ),
        title: Text(
          titleText,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text('ID: ${peer['deviceId']}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  label: Text(trustLabel),
                  visualDensity: VisualDensity.compact,
                ),
                if (isTrusted)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isOnline ? Icons.circle : Icons.circle_outlined,
                        size: 12,
                        color: isOnline ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isOnline ? 'Online' : 'Offline',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: isOnline ? Colors.green : Colors.grey,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (isTrusted &&
                peer['capabilities'] is List &&
                (peer['capabilities'] as List).isNotEmpty)
              _buildCapabilityBadges(peer['capabilities'] as List),
            if (!isTrusted && peer['address'] != null)
              Text('Address: ${peer['address']}:${peer['port']}',
                  style: theme.textTheme.bodySmall),
          ],
        ),
        trailing: isTrusted
            ? IconButton(
                icon: Icon(_trustedActionIcon(trustState)),
                tooltip: _trustedActionTooltip(trustState),
                onPressed: () => _handlePeerAction(
                  peer: peer,
                  isTrusted: isTrusted,
                  trustState: trustState,
                  titleText: titleText,
                ),
              )
            : ElevatedButton(
                onPressed: () => _handlePeerAction(
                  peer: peer,
                  isTrusted: isTrusted,
                  trustState: trustState,
                  titleText: titleText,
                ),
                child: const Text('Pair'),
              ),
      ),
    );
  }

  Widget _buildCapabilityBadges(List<dynamic> capabilities) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: capabilities.map((c) {
        final cap = c.toString();
        IconData icon = Icons.extension;
        String label = cap;
        if (cap.startsWith('clipboard.')) {
          icon = Icons.content_copy;
          label = 'Clipboard';
        } else if (cap.startsWith('presence.')) {
          icon = Icons.sensors;
          label = 'Presence';
        } else if (cap.startsWith('operation.')) {
          icon = Icons.settings_remote;
          label = 'Operations';
        } else if (cap.startsWith('security.')) {
          icon = Icons.security;
          label = 'Security';
        }

        return Tooltip(
          message: cap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _handlePeerAction({
    required Map<String, dynamic> peer,
    required bool isTrusted,
    required String trustState,
    required String titleText,
  }) async {
    final client = context.read<JsonRpcRiftClient>();
    final deviceId = peer['deviceId']?.toString();
    if (deviceId == null) return;

    try {
      if (!isTrusted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PairingScreen(
              initialDeviceId: deviceId,
              initialDisplayName: titleText,
              autoStart: true,
            ),
          ),
        );
        await _loadData();
        return;
      }

      if (trustState == 'blocked') {
        final confirmed = await _confirmTrustAction(
          title: 'Unblock device?',
          message: 'This will return $titleText to discovered state.',
          confirmLabel: 'Unblock',
        );
        if (!confirmed) return;
        await client.unblockPeer(deviceId);
      } else if (trustState == 'revoked') {
        final confirmed = await _confirmTrustAction(
          title: 'Reset revoked peer?',
          message:
              'This will clear the revoked state for $titleText and return it to discovered devices.',
          confirmLabel: 'Reset',
        );
        if (!confirmed) return;
        await client.resetRevokedPeer(deviceId);
      } else if (trustState == 'trusted' || trustState == 'pairing_pending') {
        final confirmed = await _confirmTrustAction(
          title: trustState == 'pairing_pending'
              ? 'Cancel pairing?'
              : 'Revoke trust?',
          message: trustState == 'pairing_pending'
              ? 'This will drop the pending trust flow for $titleText.'
              : 'This will revoke trust for $titleText and disconnect active sessions.',
          confirmLabel:
              trustState == 'pairing_pending' ? 'Cancel pairing' : 'Revoke',
        );
        if (!confirmed) return;
        if (trustState == 'pairing_pending') {
          await client.rejectPairing(deviceId);
        } else {
          await client.revokeTrust(
              deviceId, 'User revoked trust from device manager');
        }
      }
      await _loadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(JsonRpcRiftClient.formatDisplayError(e)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.trustedDevicesTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
        ],
      ),
      body: _error != null && _trustedPeers.isEmpty && _discoveredPeers.isEmpty
          ? Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 16),
                  Text('Error loading devices: $_error',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                      onPressed: _loadData, child: const Text('Retry'))
                ]))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text(
                      'Trusted Devices',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_trustedPeers.isEmpty)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('No trusted devices found.'),
                    )
                  else
                    ..._trustedPeers.map((p) => _buildPeerCard(p, true)),

                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text(
                      'Discovered Devices',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_discoveredPeers.isEmpty)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('No new devices discovered in your network.'),
                    )
                  else
                    ..._discoveredPeers.map((p) => _buildPeerCard(p, false)),

                  const SizedBox(height: 80), // Fab spacing
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleDiscovery,
        icon: Icon(_isDiscovering ? Icons.search_off : Icons.search),
        label: Text(_isDiscovering ? 'Stop Discovery' : 'Discover Devices'),
      ),
    );
  }
}
