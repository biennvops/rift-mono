import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import '../widgets/rift_snackbar.dart';

class DeviceDetailScreen extends StatefulWidget {
  final Map<String, dynamic> peer;
  final bool isOnline;
  final VoidCallback? onClose;

  const DeviceDetailScreen({
    this.onClose,
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
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.warning,
                      color: theme.colorScheme.onErrorContainer,
                      size: 32,
                    ),
                  ),
                ),
                Text(
                  'Revoke Trust?',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    children: [
                      const TextSpan(text: 'This will stop all communication with '),
                      TextSpan(
                        text: displayName,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const TextSpan(text: '. You will need to re-pair to restore access.'),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isMobile = constraints.maxWidth < 300;
                    if (isMobile) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                              foregroundColor: theme.colorScheme.onError,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Revoke Trust', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: theme.colorScheme.primary,
                              side: BorderSide(color: theme.colorScheme.primary),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: theme.colorScheme.primary,
                              side: BorderSide(color: theme.colorScheme.primary),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                              foregroundColor: theme.colorScheme.onError,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Revoke Trust', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                        ),
                      ],
                    );
                  }
                ),
              ],
            ),
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
                'Block $displayName?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'This device will be blocked permanently. All connections from this Ed25519 key will be automatically rejected.',
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
                    'Block permanently',
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
                    'Cancel',
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
      if (widget.onClose != null) {
        widget.onClose!();
      } else {
        Navigator.of(context).pop({
          'action': 'forgotten',
          'deviceId': deviceId,
          'displayName': displayName,
        });
      }
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'Error: $e',
        type: RiftSnackbarType.error,
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

    RiftSnackbar.show(
      context: context,
      message: 'Block not implemented in daemon yet',
      type: RiftSnackbarType.warning,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final isMobile = constraints.maxWidth < 768;
    
    final deviceId = peer['deviceId']?.toString() ?? 'Unknown ID';
    final displayName = peer['displayName']?.toString() ?? deviceId;
    final fingerprint = peer['fingerprint']?.toString() ?? '';
    final protocolVersion = peer['protocolVersion']?.toString() ?? 'v2.4.0';
    final platform = peer['platform']?.toString() ?? 'Unknown';
    final osVersion = peer['osVersion']?.toString() ?? 'Unavailable';
    final pairedAt = _formatTimestamp(peer['pairedAt']?.toString());
    final lastSeenAt = _formatTimestamp(peer['lastSeenAt']?.toString());
    final isOnline = this.isOnline;

    if (_wasRemoved) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: _buildRemovedState(theme, displayName),
      );
    }

    Widget mainContent = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Trust Status Card
        Container(
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned(
                  top: 0, left: 0, right: 0, height: 4,
                  child: Container(color: const Color(0xFF4caf50)),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Trust Status', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface)),
                                const SizedBox(height: 4),
                                Text('This device is currently authorized to sync data.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.secondary)),
                              ],
                            ),
                          ),
                          const Icon(Icons.verified_user, color: Color(0xFF4caf50), size: 32),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.colorScheme.outlineVariant),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Status', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurface)),
                                const SizedBox(width: 16),
                                Expanded(child: Text('Trusted Peer', textAlign: TextAlign.right, style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF1b5e20), fontWeight: FontWeight.bold))),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8.0),
                              child: Divider(height: 1, color: theme.colorScheme.outlineVariant),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Trust Established', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurface)),
                                const SizedBox(width: 16),
                                Expanded(child: Text(pairedAt, textAlign: TextAlign.right, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.secondary))),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Identity Card
        Container(
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Identity', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface)),
              const SizedBox(height: 16),
              _buildIdentityRow(theme, Icons.badge, 'Device ID', deviceId, isCode: true),
              _buildIdentityRow(theme, Icons.fingerprint, 'Fingerprint', _formatFingerprintWithColons(fingerprint), isCode: true),
              _buildIdentityRow(theme, Icons.desktop_windows, 'Platform', platform.toUpperCase()),
              _buildIdentityRow(theme, Icons.info, 'OS Version', osVersion),
              _buildIdentityRow(theme, Icons.dns, 'Rift Client Version', protocolVersion, isLast: true),
            ],
          ),
        ),

        // Capabilities Card
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Capabilities', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface)),
              const SizedBox(height: 4),
              Text('Manage what data can be synchronized with this device.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.secondary)),
              const SizedBox(height: 16),
              _buildCapabilityToggle(theme, Icons.content_paste, 'Clipboard Sync', 'Allow shared clipboard access', true),
              const SizedBox(height: 12),
              _buildCapabilityToggle(theme, Icons.chevron_right, 'File Transfer', 'Allow secure file dropping', true),
            ],
          ),
        ),
      ],
    );

    Widget sidePanel = Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Actions', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface)),
          const SizedBox(height: 16),
          Text('Device Name', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.secondary)),
          const SizedBox(height: 4),
          TextField(
            controller: TextEditingController(text: displayName),
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
            decoration: InputDecoration(
              filled: true,
              fillColor: theme.colorScheme.surface,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.colorScheme.outlineVariant)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.colorScheme.primary)),
            ),
            readOnly: true,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24.0),
            child: Divider(height: 1, color: theme.colorScheme.outlineVariant),
          ),
          OutlinedButton.icon(
            onPressed: _forgetPeer,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              side: BorderSide(color: theme.colorScheme.error),
              padding: const EdgeInsets.symmetric(vertical: 16),
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.delete_outline, size: 20),
            label: const Text('Revoke Trust', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _blockPeer,
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
              padding: const EdgeInsets.symmetric(vertical: 16),
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.block, size: 20),
            label: const Text('Block Device', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 32, vertical: 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 896), // max-w-4xl
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Container(
                    margin: const EdgeInsets.only(bottom: 32),
                    padding: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: widget.onClose != null ? const Icon(Icons.close) : const Icon(Icons.arrow_back),
                          color: theme.colorScheme.secondary,
                          onPressed: () {
                            if (widget.onClose != null) {
                              widget.onClose!();
                            } else {
                              Navigator.of(context).pop();
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: theme.colorScheme.outlineVariant),
                          ),
                          child: Icon(_platformIcon(platform), color: theme.colorScheme.primary, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayName,
                                style: (isMobile ? theme.textTheme.headlineSmall : theme.textTheme.headlineMedium)?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: isOnline ? const Color(0xFFe8f5e9) : theme.colorScheme.surfaceContainer,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          margin: const EdgeInsets.only(right: 6),
                                          decoration: BoxDecoration(
                                            color: isOnline ? const Color(0xFF4caf50) : theme.colorScheme.outline,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        Text(
                                          isOnline ? 'Online' : 'Offline',
                                          style: theme.textTheme.labelSmall?.copyWith(color: isOnline ? const Color(0xFF1b5e20) : theme.colorScheme.onSurfaceVariant),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('Last seen $lastSeenAt', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Grid Layout
                  if (isMobile)
                    Column(
                      children: [
                        mainContent,
                        const SizedBox(height: 24),
                        sidePanel,
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 2, child: mainContent),
                        const SizedBox(width: 24),
                        Expanded(flex: 1, child: sidePanel),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
      }
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

  Widget _buildIdentityRow(ThemeData theme, IconData icon, String label, String value, {bool isCode = false, bool isLast = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.secondary),
              const SizedBox(width: 8),
              Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.secondary)),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: isCode
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: theme.colorScheme.outlineVariant),
                        ),
                        child: Text(value, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.onSurface)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {}, // copy action
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Icon(Icons.copy, size: 18, color: theme.colorScheme.primary),
                      ),
                    ),
                  ],
                )
              : Text(value, textAlign: TextAlign.right, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
          ),
        ],
      ),
    );
  }

  Widget _buildCapabilityToggle(ThemeData theme, IconData icon, String title, String subtitle, bool enabled) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurface)),
                Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary)),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (val) {},
            activeThumbColor: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }
}
