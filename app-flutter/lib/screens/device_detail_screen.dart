import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import '../src/media_playback/playback_presentation.dart';
import '../widgets/device_focus/device_detail_content.dart';
import '../widgets/device_focus/device_focus_view.dart';
import '../widgets/device_hub/device_platform_presentation.dart';
import '../widgets/device_hub/device_summary_status.dart';
import '../widgets/device_hub/orbit_peer_presentation.dart';
import '../widgets/rift_snackbar.dart';

class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({
    super.key,
    required this.peer,
    required this.isOnline,
    this.isSelf = false,
    this.mediaPlayback,
    this.onClose,
    this.onOpenClipboardActivity,
    this.onSendFile,
    this.onViewTransferActivity,
  });

  final Map<String, dynamic> peer;
  final bool isOnline;
  final bool isSelf;
  final MediaPlaybackPresentation? mediaPlayback;
  final VoidCallback? onOpenClipboardActivity;
  final VoidCallback? onSendFile;
  final VoidCallback? onViewTransferActivity;
  final VoidCallback? onClose;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  static const _deviceStatusStaleAfter = Duration(minutes: 30);

  late Map<String, dynamic> peer;
  late bool isOnline;
  String get _deviceId => peer['deviceId']?.toString() ?? '';
  bool _wasRemoved = false;
  bool _isRefreshing = false;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<Map<String, dynamic>>? _peerLostSub;
  StreamSubscription<Map<String, dynamic>>? _deviceStatusSub;
  StreamSubscription<bool>? _connectionChangedSub;
  Timer? _deviceStatusStaleTimer;

  @override
  void initState() {
    super.initState();
    peer = widget.peer;
    isOnline = widget.isOnline;
    _scheduleDeviceStatusStaleTransition();
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
      _scheduleDeviceStatusStaleTransition();
    }
  }

  @override
  void dispose() {
    _trustChangedSub?.cancel();
    _peerLostSub?.cancel();
    _deviceStatusSub?.cancel();
    _connectionChangedSub?.cancel();
    _deviceStatusStaleTimer?.cancel();
    super.dispose();
  }

  void _subscribeToPeerUpdates() {
    final client = context.read<JsonRpcRiftClient>();
    _trustChangedSub = client.onTrustChanged.listen(_handleTrustChanged);
    _peerLostSub = client.onPeerLost.listen(_handlePeerLost);
    _deviceStatusSub = client.onDeviceStatusUpdated.listen(_handleDeviceStatus);
    _connectionChangedSub = client.onConnectionChanged.listen((isConnected) {
      if (!mounted) return;
      if (isConnected) {
        unawaited(_refreshPeerFromDaemon());
      }
    });
  }

  void _scheduleDeviceStatusStaleTransition() {
    _deviceStatusStaleTimer?.cancel();
    final status = peer['deviceStatus'];
    if (status is! Map || status['isStale'] == true) {
      return;
    }
    _deviceStatusStaleTimer = Timer(_deviceStatusStaleAfter, () {
      if (!mounted) return;
      final currentStatus = peer['deviceStatus'];
      if (currentStatus is! Map || currentStatus['isStale'] == true) {
        return;
      }
      setState(() {
        peer = Map<String, dynamic>.from(peer)
          ..['deviceStatus'] =
              (Map<String, dynamic>.from(currentStatus)..['isStale'] = true);
      });
    });
  }

  void _handleTrustChanged(Map<String, dynamic> event) {
    final eventDeviceId = event['deviceId']?.toString();
    if (eventDeviceId == null || eventDeviceId != _deviceId) return;

    final newState = event['newState']?.toString();
    if (newState == 'trusted') {
      unawaited(_refreshPeerFromDaemon());
      return;
    }

    if (!mounted) return;
    _deviceStatusStaleTimer?.cancel();
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
    _deviceStatusStaleTimer?.cancel();
    setState(() {
      isOnline = false;
      final status = peer['deviceStatus'];
      if (status is Map) {
        peer = Map<String, dynamic>.from(peer)
          ..['deviceStatus'] =
              (Map<String, dynamic>.from(status)..['isStale'] = true);
      }
    });
  }

  void _handleDeviceStatus(Map<String, dynamic> event) {
    if (event['sourceDeviceId']?.toString() != _deviceId || !mounted) return;
    setState(() {
      peer = Map<String, dynamic>.from(peer)
        ..['deviceStatus'] = Map<String, dynamic>.from(event);
    });
    _scheduleDeviceStatusStaleTransition();
  }

  Future<void> _refreshPeerFromDaemon() async {
    if (!mounted || _deviceId.isEmpty || _isRefreshing) return;

    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) return;

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
        _deviceStatusStaleTimer?.cancel();
        setState(() {
          _wasRemoved = true;
          isOnline = false;
        });
        return;
      }

      setState(() {
        peer = refreshedPeer!;
        isOnline = isTrustedDeviceOnline(refreshedPeer);
        _wasRemoved = false;
      });
      _scheduleDeviceStatusStaleTransition();
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

  String _formatFingerprint(String fingerprint) {
    final clean =
        fingerprint.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.isEmpty) return 'Unavailable';
    final chunks = <String>[];
    for (var index = 0; index < clean.length; index += 4) {
      chunks.add(
        clean.substring(
          index,
          (index + 4) > clean.length ? clean.length : index + 4,
        ),
      );
    }
    return chunks.join('-');
  }

  String _diagnosticValue(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? 'Unavailable' : text;
  }

  void _copyToClipboard(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    RiftSnackbar.show(
      context: context,
      message: message,
      type: RiftSnackbarType.success,
    );
  }

  Future<bool> _showRevokeDialog(String displayName) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('Revoke Trust?'),
          content: Text(
            'This will stop all communication with $displayName. '
            'You will need to re-pair to restore access.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              child: const Text('Revoke Trust'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _forgetPeer() async {
    final deviceId = peer['deviceId']?.toString();
    final displayName = resolveDeviceDisplayName(peer);
    if (deviceId == null) return;

    final confirmed = await _showRevokeDialog(displayName);
    if (!confirmed || !mounted) return;

    final client = context.read<JsonRpcRiftClient>();
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
    } catch (error) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'Error: $error',
        type: RiftSnackbarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rawDeviceId = peer['deviceId']?.toString().trim() ?? '';
    final deviceStatus = peer['deviceStatus'] is Map
        ? Map<String, dynamic>.from(peer['deviceStatus'] as Map)
        : null;
    final presentation = widget.isSelf
        ? buildLocalDevicePresentation(
            device: peer,
            deviceStatus: deviceStatus,
            mediaPlayback: widget.mediaPlayback,
          )
        : buildTrustedDevicePresentation(
            peer: peer,
            deviceStatus: deviceStatus,
            mediaPlayback: widget.mediaPlayback,
            isOnline: isOnline,
          );
    final deviceId = rawDeviceId.isEmpty ? 'Unknown ID' : rawDeviceId;
    final rawPlatform = peer['platform']?.toString().trim() ?? '';
    final platformLabel = devicePlatformLabel(presentation.platform) ??
        (rawPlatform.isEmpty ? 'Unknown' : rawPlatform);
    final fingerprint = _formatFingerprint(_resolveFingerprint(deviceId));
    final protocolVersion = _diagnosticValue(peer['protocolVersion']);
    final osVersion = _diagnosticValue(peer['osVersion']);
    final pairedAt = formatDeviceTimestamp(peer['pairedAt']?.toString());
    final lastSeenAt = formatDeviceTimestamp(peer['lastSeenAt']?.toString());
    final capabilities = (peer['capabilities'] as List?)
            ?.map((capability) => capability.toString())
            .toList(growable: false) ??
        const <String>[];

    if (_wasRemoved) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: _buildRemovedState(theme, presentation.displayName),
      );
    }

    final useDesktopFocusView = widget.onClose != null &&
        (widget.isSelf || peer['trustState']?.toString() == 'trusted');
    if (useDesktopFocusView) {
      return DeviceFocusView(
        presentation: presentation,
        fingerprint: fingerprint,
        protocolVersion: protocolVersion,
        osVersion: osVersion,
        pairedAt: pairedAt,
        lastSeenAt: lastSeenAt,
        capabilities: capabilities,
        deviceStatus: deviceStatus,
        mediaPlayback: widget.mediaPlayback,
        onClose: widget.onClose!,
        onRevokeTrust: widget.isSelf ? null : _forgetPeer,
        onCopy: _copyToClipboard,
        onOpenClipboardActivity: widget.onOpenClipboardActivity,
        onSendFile: widget.onSendFile,
        onViewTransferActivity: widget.onViewTransferActivity,
      );
    }

    return _buildMobileDetail(
      theme: theme,
      presentation: presentation,
      platformLabel: platformLabel,
      deviceId: deviceId,
      fingerprint: fingerprint,
      protocolVersion: protocolVersion,
      osVersion: osVersion,
      pairedAt: pairedAt,
      lastSeenAt: lastSeenAt,
      capabilities: capabilities,
      deviceStatus: deviceStatus,
    );
  }

  Widget _buildMobileDetail({
    required ThemeData theme,
    required OrbitPeerPresentation presentation,
    required String platformLabel,
    required String deviceId,
    required String fingerprint,
    required String protocolVersion,
    required String osVersion,
    required String pairedAt,
    required String lastSeenAt,
    required List<String> capabilities,
    required Map<String, dynamic>? deviceStatus,
  }) {
    final colors = theme.colorScheme;
    final liveMedia = presentation.activity == OrbitPeerActivity.none
        ? null
        : widget.mediaPlayback;
    final showMedia = widget.isSelf ||
        capabilities.contains('media.playback') ||
        widget.mediaPlayback != null;
    final mediaAccent = liveMedia?.accentColor ?? colors.primary;
    final showSecurity =
        !widget.isSelf && peer['trustState']?.toString() == 'trusted';

    return Scaffold(
      key: const ValueKey('device-detail-mobile'),
      backgroundColor: colors.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildMobileHeader(theme, presentation, platformLabel),
                  const SizedBox(height: 24),
                  if (showMedia) ...[
                    _DeviceDetailSection(
                      key: const ValueKey('device-detail-section-media'),
                      title: 'Media',
                      icon: Icons.graphic_eq,
                      accentColor: mediaAccent,
                      child: DeviceMediaDetailsView(
                        media: liveMedia,
                        accentColor: mediaAccent,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (deviceStatus != null) ...[
                    _DeviceDetailSection(
                      key: const ValueKey('device-detail-section-power'),
                      title: 'Power status',
                      icon: Icons.battery_charging_full,
                      child: _buildPowerDetails(
                        deviceStatus,
                        presentation.isOnline,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _DeviceDetailSection(
                    key: const ValueKey('device-detail-section-features'),
                    title: 'Features',
                    icon: Icons.extension_outlined,
                    child: DeviceFeaturesView(
                      capabilities: capabilities,
                      onOpenClipboardActivity: widget.onOpenClipboardActivity,
                      onSendFile: widget.onSendFile,
                      onViewTransferActivity: widget.onViewTransferActivity,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (showSecurity) ...[
                    _DeviceDetailSection(
                      key: const ValueKey('device-detail-section-security'),
                      title: 'Security',
                      icon: Icons.verified_user_outlined,
                      child: _buildSecurityDetails(
                        theme,
                        pairedAt,
                        fingerprint,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _DeviceDetailSection(
                    key: const ValueKey('device-detail-section-identity'),
                    title: 'Identity',
                    icon: Icons.badge_outlined,
                    child: _buildIdentityDetails(
                      presentation: presentation,
                      platformLabel: platformLabel,
                      deviceId: deviceId,
                      fingerprint: fingerprint,
                      protocolVersion: protocolVersion,
                      osVersion: osVersion,
                      lastSeenAt: lastSeenAt,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileHeader(
    ThemeData theme,
    OrbitPeerPresentation presentation,
    String platformLabel,
  ) {
    final colors = theme.colorScheme;
    final hasLiveSummary = !widget.isSelf ||
        presentation.powerStatus != null ||
        presentation.mediaStateLabel != null;

    return Column(
      key: const ValueKey('device-detail-header'),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            key: const ValueKey('device-detail-back'),
            tooltip: 'Back',
            onPressed: widget.onClose ?? () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
            color: colors.onSurfaceVariant,
          ),
        ),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            devicePlatformIcon(presentation.platform),
            size: 32,
            color: colors.primary,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          presentation.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          platformLabel,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        if (hasLiveSummary) ...[
          const SizedBox(height: 8),
          DeviceSummaryStatus(
            key: const ValueKey('device-detail-summary'),
            presentation: presentation,
            accentColor: colors.primary,
            alignment: WrapAlignment.center,
            showStatus: !widget.isSelf,
          ),
        ],
      ],
    );
  }

  Widget _buildPowerDetails(
    Map<String, dynamic> status,
    bool isOnline,
  ) {
    final details = DevicePowerDetails.fromStatus(
      status,
      isOnline: isOnline,
    );
    return _buildRows(
      details.rows
          .map(
            (row) => _MobileDetailRow(
              icon: _powerRowIcon(row.label),
              label: row.label,
              value: row.value,
            ),
          )
          .toList(growable: false),
    );
  }

  IconData _powerRowIcon(String label) => switch (label) {
        'Battery' => Icons.battery_std,
        'Charging state' => Icons.battery_charging_full,
        'Power source' => Icons.power,
        'Low Power Mode' => Icons.energy_savings_leaf_outlined,
        _ => Icons.schedule,
      };

  Widget _buildSecurityDetails(
    ThemeData theme,
    String pairedAt,
    String fingerprint,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildRows([
          const _MobileDetailRow(
            icon: Icons.verified_user_outlined,
            label: 'Trust',
            value: 'Trusted',
          ),
          _MobileDetailRow(
            icon: Icons.event_available_outlined,
            label: 'Trust established',
            value: pairedAt,
          ),
          _MobileDetailRow(
            icon: Icons.fingerprint,
            label: 'Fingerprint',
            value: fingerprint,
            monospace: true,
          ),
        ]),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (fingerprint != 'Unavailable')
              OutlinedButton.icon(
                key: const ValueKey('device-detail-copy-fingerprint'),
                onPressed: () => _copyToClipboard(
                  fingerprint,
                  'Fingerprint copied to clipboard',
                ),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy fingerprint'),
              ),
            OutlinedButton.icon(
              key: const ValueKey('device-detail-revoke-trust'),
              onPressed: _forgetPeer,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error),
              ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Revoke Trust'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildIdentityDetails({
    required OrbitPeerPresentation presentation,
    required String platformLabel,
    required String deviceId,
    required String fingerprint,
    required String protocolVersion,
    required String osVersion,
    required String lastSeenAt,
  }) {
    final rows = <Widget>[
      _MobileDetailRow(
        icon: Icons.badge_outlined,
        label: 'Device ID',
        value: deviceId,
        monospace: true,
        onCopy: deviceId == 'Unknown ID'
            ? null
            : () => _copyToClipboard(
                  deviceId,
                  'Device ID copied to clipboard',
                ),
      ),
      if (widget.isSelf)
        _MobileDetailRow(
          icon: Icons.fingerprint,
          label: 'Fingerprint',
          value: fingerprint,
          monospace: true,
          onCopy: fingerprint != 'Unavailable'
              ? () => _copyToClipboard(
                    fingerprint,
                    'Fingerprint copied to clipboard',
                  )
              : null,
        ),
      _MobileDetailRow(
        icon: devicePlatformIcon(presentation.platform),
        label: 'Platform',
        value: platformLabel,
      ),
      _MobileDetailRow(
        icon: Icons.info_outline,
        label: 'OS Version',
        value: osVersion,
      ),
      _MobileDetailRow(
        icon: Icons.dns_outlined,
        label: 'Rift Client / Protocol Version',
        value: protocolVersion,
      ),
      if (!widget.isSelf)
        _MobileDetailRow(
          icon: Icons.history,
          label: 'Last seen',
          value: lastSeenAt,
        ),
    ];
    return _buildRows(rows);
  }

  Widget _buildRows(List<Widget> rows) {
    return Column(
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          rows[index],
          if (index != rows.length - 1) const Divider(height: 1),
        ],
      ],
    );
  }

  Widget _buildRemovedState(ThemeData theme, String displayName) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
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
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This trusted device was removed or is no longer in your '
                'trusted list. Return to the home screen to continue.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
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
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceDetailSection extends StatelessWidget {
  const _DeviceDetailSection({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.accentColor,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = accentColor ?? colors.primary;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 20, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _MobileDetailRow extends StatelessWidget {
  const _MobileDetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.monospace = false,
    this.onCopy,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool monospace;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 19, color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface,
                    fontFamily: monospace ? 'JetBrains Mono' : null,
                  ),
                ),
              ],
            ),
          ),
          if (onCopy != null) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Copy $label',
              visualDensity: VisualDensity.compact,
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 18),
              color: colors.primary,
            ),
          ],
        ],
      ),
    );
  }
}
