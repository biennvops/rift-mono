import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import '../widgets/rift_snackbar.dart';

const _kSuccessColor = Color(0xFF047857);
const _kSuccessBgColor = Color(0x14047857);

class DeviceDetailScreen extends StatefulWidget {
  final Map<String, dynamic> peer;
  final bool isOnline;
  final bool isSelf;
  final VoidCallback? onClose;

  const DeviceDetailScreen({
    this.onClose,
    super.key,
    required this.peer,
    required this.isOnline,
    this.isSelf = false,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  late Map<String, dynamic> peer;
  late bool isOnline;
  String get _deviceId => peer['deviceId']?.toString() ?? '';
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
    if (!widget.isSelf) {
      _subscribeToPeerUpdates();
    }
  }

  @override
  void didUpdateWidget(DeviceDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peer != widget.peer ||
        oldWidget.isOnline != widget.isOnline ||
        oldWidget.isSelf != widget.isSelf) {
      setState(() {
        peer = widget.peer;
        isOnline = widget.isOnline;
      });
    }
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
    } finally {
      _isRefreshing = false;
    }
  }

  String _resolveFingerprint(String deviceId) {
    final payloadFingerprint =
        peer['fingerprint']?.toString() ?? peer['peerFingerprint']?.toString();
    if (payloadFingerprint != null && payloadFingerprint.trim().isNotEmpty) {
      return payloadFingerprint;
    }
    return deviceId.toLowerCase().startsWith('rift-')
        ? deviceId.substring(5)
        : '';
  }

  String _formatFingerprint(String fp) {
    final clean = fp.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.isEmpty) return 'Unavailable';
    final chunks = <String>[];
    for (int i = 0; i < clean.length; i += 4) {
      chunks.add(
        clean.substring(i, (i + 4) > clean.length ? clean.length : i + 4),
      );
    }
    return chunks.join('-');
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

  void _copyToClipboard(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    RiftSnackbar.show(
      context: context,
      message: message,
      type: RiftSnackbarType.success,
    );
  }

  Future<bool> _showForgetBottomSheet(
    String displayName,
    String fingerprint,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dialogTheme = Theme.of(ctx);
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: dialogTheme.colorScheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: dialogTheme.colorScheme.primaryContainer
                      .withValues(alpha: 0.1),
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
                    color: dialogTheme.colorScheme.errorContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.warning,
                      color: dialogTheme.colorScheme.onErrorContainer,
                      size: 32,
                    ),
                  ),
                ),
                Text(
                  'Revoke Trust?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.01,
                    height: 32 / 24,
                    color: dialogTheme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      height: 24 / 16,
                      color: dialogTheme.colorScheme.onSurfaceVariant,
                    ),
                    children: [
                      const TextSpan(
                          text: 'This will stop all communication with '),
                      TextSpan(
                        text: displayName,
                        style: TextStyle(
                          color: dialogTheme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const TextSpan(
                          text:
                              '. You will need to re-pair to restore access.'),
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
                              backgroundColor: dialogTheme.colorScheme.error,
                              foregroundColor: dialogTheme.colorScheme.onError,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4)),
                            ),
                            child: const Text('Revoke Trust',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor:
                                  dialogTheme.colorScheme.primaryContainer,
                              side: BorderSide(
                                  color:
                                      dialogTheme.colorScheme.primaryContainer),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4)),
                            ),
                            child: const Text('Cancel',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
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
                              foregroundColor:
                                  dialogTheme.colorScheme.primaryContainer,
                              side: BorderSide(
                                  color:
                                      dialogTheme.colorScheme.primaryContainer),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4)),
                            ),
                            child: const Text('Cancel',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            style: FilledButton.styleFrom(
                              backgroundColor: dialogTheme.colorScheme.error,
                              foregroundColor: dialogTheme.colorScheme.onError,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4)),
                            ),
                            child: const Text('Revoke Trust',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final isEmbedded = widget.onClose != null;
        final isMobile = isEmbedded || constraints.maxWidth < 768;

        final deviceId = peer['deviceId']?.toString() ?? 'Unknown ID';
        final displayName = peer['displayName']?.toString() ?? deviceId;
        final fingerprint = _resolveFingerprint(deviceId);
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
            if (!widget.isSelf)
              Container(
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 4,
                        child: Container(color: _kSuccessColor),
                      ),
                      Padding(
                        padding: EdgeInsets.all(isMobile ? 16 : 20),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                color: _kSuccessBgColor,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.verified_user,
                                  color: _kSuccessColor, size: 22),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Authorized Trusted Peer',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Trust established $pairedAt',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
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
            Container(
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              padding: EdgeInsets.all(isMobile ? 16 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isSelf ? 'Device details' : 'Identity',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.01,
                      height: 32 / 24,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildIdentityRow(theme, Icons.badge, 'Device ID', deviceId,
                      isCode: true),
                  _buildIdentityRow(theme, Icons.fingerprint, 'Fingerprint',
                      _formatFingerprint(fingerprint),
                      isCode: true),
                  _buildIdentityRow(theme, Icons.desktop_windows, 'Platform',
                      platform.toUpperCase()),
                  _buildIdentityRow(theme, Icons.info, 'OS Version', osVersion),
                  _buildIdentityRow(
                      theme, Icons.dns, 'Rift Client Version', protocolVersion,
                      isLast: true),
                ],
              ),
            ),
            if (!widget.isSelf)
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: EdgeInsets.all(isMobile ? 16 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Capabilities',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.01,
                        height: 32 / 24,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Manage what data can be synchronized with this device.',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        height: 24 / 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildCapabilityToggle(theme, Icons.content_paste,
                        'Clipboard Sync', 'Allow shared clipboard access', true),
                    const SizedBox(height: 12),
                    _buildCapabilityToggle(theme, Icons.chevron_right,
                        'File Transfer', 'Allow secure file dropping', true),
                  ],
                ),
              ),
          ],
        );

        Widget sidePanel = Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          padding: EdgeInsets.all(isMobile ? 16 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Actions',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.01,
                  height: 32 / 24,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Device Name',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 20 / 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: TextEditingController(text: displayName),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  height: 24 / 16,
                  color: theme.colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  filled: false,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide:
                          BorderSide(color: theme.colorScheme.outlineVariant)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(
                          color: theme.colorScheme.primaryContainer, width: 2)),
                ),
                readOnly: true,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child:
                    Divider(height: 1, color: theme.colorScheme.outlineVariant),
              ),
              if (widget.isSelf) ...[
                OutlinedButton.icon(
                  onPressed: () => _copyToClipboard(
                      deviceId, 'Device ID copied to clipboard'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primaryContainer,
                    side: BorderSide(color: theme.colorScheme.primaryContainer),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    minimumSize: const Size(double.infinity, 44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy Device ID',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _copyToClipboard(
                      _formatFingerprint(fingerprint),
                      'Fingerprint copied to clipboard'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primaryContainer,
                    side: BorderSide(color: theme.colorScheme.primaryContainer),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    minimumSize: const Size(double.infinity, 44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy Fingerprint',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ] else
                OutlinedButton.icon(
                  onPressed: _forgetPeer,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 20),
                  label: const Text('Revoke Trust',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        );

        return Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 16 : 32, vertical: 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 896),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(bottom: 32),
                        padding: const EdgeInsets.only(bottom: 24),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: theme.colorScheme.outlineVariant)),
                        ),
                        child: Row(
                          children: [
                            if (widget.onClose == null) ...[
                              IconButton(
                                icon: const Icon(Icons.arrow_back),
                                color: theme.colorScheme.onSurfaceVariant,
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: theme.colorScheme.outlineVariant),
                              ),
                              child: Icon(_platformIcon(platform),
                                  color: theme.colorScheme.primary, size: 28),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    displayName,
                                    style: TextStyle(
                                      fontSize: isMobile ? 24 : 32,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: isMobile ? -0.01 : -0.02,
                                      height: isMobile ? 32 / 24 : 40 / 32,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: isOnline
                                              ? _kSuccessBgColor
                                              : theme
                                                  .colorScheme.surfaceContainer,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 8,
                                              height: 8,
                                              margin: const EdgeInsets.only(
                                                  right: 6),
                                              decoration: BoxDecoration(
                                                color: isOnline
                                                    ? _kSuccessColor
                                                    : theme.colorScheme.outline,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            Text(
                                              widget.isSelf
                                                  ? 'This Device'
                                                  : (isOnline
                                                      ? 'Online'
                                                      : 'Offline'),
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                                height: 16 / 12,
                                                color: isOnline
                                                    ? _kSuccessColor
                                                    : theme.colorScheme
                                                        .onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Text(
                                        widget.isSelf
                                            ? 'Local host device'
                                            : 'Last seen $lastSeenAt',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                          height: 20 / 14,
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
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
      },
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
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.01,
                height: 32 / 24,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This trusted device was removed or is no longer in your trusted list. Return to the home screen to continue.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w400,
                height: 24 / 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  if (widget.onClose != null) {
                    widget.onClose!();
                  } else {
                    Navigator.of(context).pop({
                      'action': 'removed',
                      'deviceId': _deviceId,
                      'displayName': displayName,
                    });
                  }
                },
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  foregroundColor: theme.colorScheme.onPrimary,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4)),
                ),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to home',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdentityRow(
      ThemeData theme, IconData icon, String label, String value,
      {bool isCode = false, bool isLast = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 20 / 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: isCode
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: theme.colorScheme.outlineVariant),
                          ),
                          child: Text(
                            value,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: 'JetBrains Mono',
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              height: 20 / 14,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: value));
                          if (!mounted) return;
                          RiftSnackbar.show(
                            context: context,
                            message: 'Copied to clipboard',
                            type: RiftSnackbarType.success,
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: Icon(Icons.copy,
                              size: 18,
                              color: theme.colorScheme.primaryContainer),
                        ),
                      ),
                    ],
                  )
                : Text(value,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      height: 24 / 16,
                      color: theme.colorScheme.onSurface,
                    )),
          ),
        ],
      ),
    );
  }

  Widget _buildCapabilityToggle(ThemeData theme, IconData icon, String title,
      String subtitle, bool enabled) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primaryContainer),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 24 / 16,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    height: 20 / 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (val) {},
            activeThumbColor: theme.colorScheme.onPrimary,
            activeTrackColor: theme.colorScheme.primaryContainer,
          ),
        ],
      ),
    );
  }
}
