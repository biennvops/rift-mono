import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';
import 'pairing_screen.dart';
import 'device_detail_screen.dart';
import '../widgets/rift_snackbar.dart';

class TrustedDevicesScreen extends StatefulWidget {
  const TrustedDevicesScreen({super.key});

  @override
  State<TrustedDevicesScreen> createState() => _TrustedDevicesScreenState();
}

class _TrustedDevicesScreenState extends State<TrustedDevicesScreen> {
  static const Duration _presenceRefreshInterval = Duration(seconds: 5);

  String? _localDeviceId;
  Map<String, dynamic>? _localDeviceInfo;
  bool _isDiscovering = false;
  bool _isTogglingDiscovery = false;
  List<dynamic> _trustedPeers = [];
  List<dynamic> _discoveredPeers = [];
  String? _error;
  bool _isLoadingData = false;
  bool _reloadQueued = false;
  bool _autoDiscoveryAttempted = false;

  StreamSubscription? _discoverySub;
  StreamSubscription? _peerLostSub;
  StreamSubscription? _trustSub;
  StreamSubscription? _pairingCompleteSub;
  Timer? _reloadDebounce;
  Timer? _fullReloadThrottle;
  Timer? _presenceRefreshTimer;

  bool get _isRouteCurrent {
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

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
    _connectionSub?.cancel();
    super.dispose();
  }

  StreamSubscription<bool>? _connectionSub;

  void _setupListeners() {
    final client = context.read<JsonRpcRiftClient>();
    _discoverySub = client.onPeerDiscovered.listen(_handlePeerDiscovered);
    _peerLostSub = client.onPeerLost.listen(_handlePeerLost);
    _trustSub = client.onTrustChanged.listen(_handleTrustChanged);
    _pairingCompleteSub =
        client.onPairingComplete.listen(_handlePairingComplete);
    _connectionSub = client.onConnectionChanged.listen((isConnected) {
      if (isConnected && mounted) {
        _loadData();
      }
    });
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
    final instanceId = event['instanceId']?.toString();
    final deviceId = event['deviceId']?.toString() ?? instanceId;
    if (deviceId == null || deviceId.isEmpty) return;
    if (!mounted) return;
    if (_isSelfDevice(deviceId)) return;
    if (_isPeerAlreadyManaged(deviceId)) return;

    setState(() {
      // Upsert into discovered list.
      final existing = _discoveredPeers.indexWhere((p) =>
          p is Map &&
          (p['deviceId']?.toString() == deviceId ||
              (instanceId != null &&
                  p['instanceId']?.toString() == instanceId)));
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
    final instanceId = event['instanceId']?.toString();
    if ((deviceId == null || deviceId.isEmpty) &&
        (instanceId == null || instanceId.isEmpty)) {
      return;
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _discoveredPeers = _discoveredPeers.where((p) {
        if (p is! Map) {
          return true;
        }
        final pDeviceId = p['deviceId']?.toString();
        final pInstanceId = p['instanceId']?.toString();
        if (deviceId != null && deviceId.isNotEmpty && pDeviceId == deviceId) {
          return false;
        }
        if (instanceId != null &&
            instanceId.isNotEmpty &&
            pInstanceId == instanceId) {
          return false;
        }
        return true;
      }).toList(growable: false);
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

    // We can't fully materialize trusted peer details from the event alone,
    // so do a throttled full reload. Still, update minimal local state to
    // prevent the UI from feeling stale.
    setState(() {
      // Remove from discovered if it is no longer discovered/pairing_pending.
      if (newState == 'trusted' || newState == 'blocked') {
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
    final shouldRefresh = mounted &&
        _isRouteCurrent &&
        (_trustedPeers.isNotEmpty || _isDiscovering);
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
      if (!_isRouteCurrent ||
          !client.isConnected ||
          (_trustedPeers.isEmpty && !_isDiscovering)) {
        _syncPresenceRefreshLoop();
        return;
      }
      _loadData();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPresenceRefreshLoop();
    });
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    if (_isLoadingData) {
      _reloadQueued = true;
      return;
    }

    try {
      final client = context.read<JsonRpcRiftClient>();
      _isLoadingData = true;

      // Default empty lists if not connected
      if (!client.isConnected) {
        setState(() {
          _trustedPeers = [];
          _discoveredPeers = [];
          _localDeviceInfo = null;
          _isDiscovering = false;
          _error = 'Daemon not connected';
        });
        _syncPresenceRefreshLoop();
        return;
      }

      final deviceInfo = await client.getDeviceInfo() as Map;
      final trustedResult = await client.listTrustedPeers();
      final discoveredResult = await client.listDiscoveredPeers();
      final localDeviceId = deviceInfo['deviceId']?.toString();
      final trustedPeers =
          List<dynamic>.from(trustedResult['peers'] ?? const []);
      final discoveredPeers = _filterDiscoverablePeers(
        trustedPeers: trustedPeers,
        discoveredPeers: List<dynamic>.from(
          discoveredResult['peers'] ?? const [],
        ),
      );
      final isDiscovering = discoveredResult['isDiscovering'] == true;
      if (mounted) {
        setState(() {
          _localDeviceId = localDeviceId;
          _localDeviceInfo = Map<String, dynamic>.from(deviceInfo);
          _trustedPeers = trustedPeers;
          _discoveredPeers = discoveredPeers;
          _isDiscovering = isDiscovering;
          _error = null;
        });
      }
      if (trustedPeers.isEmpty) {
        _autoDiscoveryAttempted = false;
      } else if (!isDiscovering) {
        unawaited(_ensureTrustedPeerDiscovery(client));
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

  bool _isSelfDevice(String deviceId) {
    final localDeviceId = _localDeviceId;
    return localDeviceId != null &&
        localDeviceId.isNotEmpty &&
        deviceId == localDeviceId;
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
      'pairing_pending',
    };

    return discoveredPeers.where((peer) {
      if (peer is! Map) return false;
      final deviceId = peer['deviceId']?.toString();
      if (deviceId == null || deviceId.isEmpty) return false;

      if (_isSelfDevice(deviceId)) return false;

      if (trustedDeviceIds.contains(deviceId)) return false;

      final trustState = peer['trustState']?.toString();
      if (trustState != null && hiddenTrustStates.contains(trustState)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  Future<void> _ensureTrustedPeerDiscovery(JsonRpcRiftClient client) async {
    if (_autoDiscoveryAttempted ||
        _trustedPeers.isEmpty ||
        _isDiscovering ||
        _isTogglingDiscovery) {
      return;
    }

    _autoDiscoveryAttempted = true;
    try {
      await client.startDiscovery();
      if (mounted) {
        setState(() {
          _isDiscovering = true;
          _error = null;
        });
      }
      _scheduleReload();
    } catch (_) {
      _autoDiscoveryAttempted = false;
    }
  }

  Future<void> _toggleDiscovery() async {
    if (_isTogglingDiscovery) return;
    setState(() {
      _isTogglingDiscovery = true;
    });

    final client = context.read<JsonRpcRiftClient>();
    try {
      if (!client.isConnected) {
        await client.connect();
      }
      if (!client.isConnected) {
        if (!mounted) return;
        RiftSnackbar.show(
          context: context,
          message: 'Daemon is still starting. Try discovery again in a moment.',
          type: RiftSnackbarType.warning,
        );
        return;
      }
      final nextDiscovering = !_isDiscovering;
      if (_isDiscovering) {
        await client.stopDiscovery();
      } else {
        await client.startDiscovery();
      }
      if (mounted) {
        setState(() {
          _isDiscovering = nextDiscovering;
          _error = null;
        });
      }
      if (!nextDiscovering) {
        _autoDiscoveryAttempted = true;
      }
      await _loadData();
    } catch (e) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: JsonRpcRiftClient.formatDisplayError(e),
          type: RiftSnackbarType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTogglingDiscovery = false;
        });
      }
    }
  }

  Future<void> _showManualPairDialog() async {
    final addressController = TextEditingController();
    final portController = TextEditingController(text: '11112');
    String? validationError;

    final result = await showDialog<({String address, int port})>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final address = addressController.text.trim();
              final portText = portController.text.trim();
              final parsedPort = int.tryParse(portText);
              final parsedAddress = InternetAddress.tryParse(address);
              if (parsedAddress == null ||
                  parsedAddress.type != InternetAddressType.IPv4) {
                setDialogState(() {
                  validationError = 'Enter a valid IPv4 address.';
                });
                return;
              }
              if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
                setDialogState(() {
                  validationError = 'Enter a TCP port between 1 and 65535.';
                });
                return;
              }
              Navigator.of(dialogContext)
                  .pop((address: address, port: parsedPort));
            }

            return AlertDialog(
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Text(
                'Pair by IP',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Enter the IPv4 address and port of the peer device.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: addressController,
                      decoration: InputDecoration(
                        labelText: 'IPv4 address',
                        hintText: '10.53.38.174',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
                      ),
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      onSubmitted: (_) => submit(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: portController,
                      decoration: InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
                      ),
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => submit(),
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        validationError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: submit,
                  child: const Text('Pair'),
                ),
              ],
            );
          },
        );
      },
    );

    if (!mounted || result == null) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Provider<JsonRpcRiftClient>.value(
          value: client,
          child: PairingScreen(
            initialEndpointAddress: result.address,
            initialEndpointPort: result.port,
            initialDisplayName: '${result.address}:${result.port}',
            autoStart: true,
          ),
        ),
      ),
    );
    await _loadData();
  }

  String _trustStateLabel(String trustState) {
    switch (trustState) {
      case 'pairing_pending':
        return 'Pairing pending';
      case 'blocked':
        return 'Blocked';
      case 'trusted':
        return 'Trusted';
      default:
        return 'Discovered';
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

  Widget _buildTrustBadge(String trustState, ThemeData theme) {
    Color bgColor;
    Color fgColor;
    Color borderColor;
    IconData icon;
    String label = _trustStateLabel(trustState).toUpperCase();

    if (trustState == 'trusted') {
      bgColor = theme.colorScheme.secondaryContainer;
      fgColor = theme.colorScheme.onSecondaryContainer;
      borderColor = theme
          .colorScheme.secondary; // equivalent to secondary-fixed for border
      icon = Icons.verified_user;
    } else if (trustState == 'blocked') {
      bgColor = theme.colorScheme.errorContainer;
      fgColor = theme.colorScheme.onErrorContainer;
      borderColor = theme.colorScheme.error;
      icon = Icons.block;
    } else {
      bgColor = theme.colorScheme.surfaceContainerHighest;
      fgColor = theme.colorScheme.onSurfaceVariant;
      borderColor = theme.colorScheme.outlineVariant;
      icon = Icons.radar;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fgColor),
          const SizedBox(width: 4),
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(color: fgColor)),
        ],
      ),
    );
  }

  Widget _buildPresenceIndicator(
      bool isOnline, ThemeData theme, String trustState) {
    if (trustState == 'blocked') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.error),
            ),
          ),
          const SizedBox(width: 4),
          Text('OFFLINE',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ],
      );
    }

    if (trustState == 'pairing_pending') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.amber,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text('PENDING',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: Colors.amber.shade800)),
        ],
      );
    }

    if (trustState == 'discovered') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.amber,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text('NEARBY',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: Colors.amber.shade800)),
        ],
      );
    }

    if (isOnline) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text('ONLINE',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.secondary)),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.outline),
          ),
        ),
        const SizedBox(width: 4),
        Text('OFFLINE',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
  }

  Widget _buildPeerCard(Map<String, dynamic> peer, bool isTrusted) {
    final isOnline = peer['presence'] == 'online';
    final trustState = peer['trustState']?.toString() ??
        (isTrusted ? 'trusted' : 'discovered');
    final theme = Theme.of(context);

    final String deviceIdStr = peer['deviceId']?.toString() ?? '';
    final String shortId =
        deviceIdStr.length > 16 ? deviceIdStr.substring(0, 16) : deviceIdStr;
    final String rawDisplayName = peer['displayName']?.toString() ?? '';
    final String peerPlatform = peer['platform']?.toString() ?? 'unknown';
    final String titleText = rawDisplayName.isNotEmpty
        ? rawDisplayName
        : (shortId.isNotEmpty ? shortId : 'Unknown Device');

    // Màn A Design uses surface-container-lowest for Trusted, surface-container-low for Discovered, and surface-container for Blocked
    Color cardBg;
    Color cardBorder = theme.colorScheme.outlineVariant;
    double opacity = 1.0;

    if (trustState == 'trusted') {
      cardBg = theme.colorScheme.surface;
    } else if (trustState == 'blocked') {
      cardBg = theme.colorScheme.surfaceContainer;
      cardBorder = theme.colorScheme.errorContainer;
      opacity = 0.6;
    } else {
      cardBg = theme.colorScheme.surfaceContainerLow;
    }

    return Opacity(
      opacity: opacity,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(_platformIcon(peerPlatform),
                          color: theme.colorScheme.outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              titleText,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: theme.colorScheme.onSurface,
                                decoration: trustState == 'blocked'
                                    ? TextDecoration.lineThrough
                                    : null,
                                decorationColor: theme.colorScheme.error,
                              ),
                            ),
                            if (deviceIdStr.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                deviceIdStr,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontFamily: 'JetBrains Mono',
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildTrustBadge(trustState, theme),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildPresenceIndicator(isOnline, theme, trustState),
                _buildActionBtn(trustState, isTrusted, peer, titleText, theme),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalDeviceCard() {
    final theme = Theme.of(context);
    final localDeviceInfo = _localDeviceInfo;
    if (localDeviceInfo == null) {
      return const SizedBox.shrink();
    }

    final deviceId = localDeviceInfo['deviceId']?.toString() ?? '';
    final displayName = localDeviceInfo['displayName']?.toString();
    final platform =
        localDeviceInfo['platform']?.toString() ?? _localPlatform();
    final titleText = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : (deviceId.isNotEmpty ? deviceId : 'This Device');

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: theme.colorScheme.primary),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_platformIcon(platform),
              color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleText,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'This device',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                if (deviceId.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    deviceId,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.82,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _platformIcon(String? platform) {
    switch (platform?.toLowerCase()) {
      case 'android':
      case 'ios':
        return Icons.smartphone;
      case 'windows':
        return Icons.laptop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.terminal;
      default:
        return Icons.devices;
    }
  }

  String _localPlatform() {
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isLinux) {
      return 'linux';
    }
    return 'unknown';
  }

  Widget _buildActionBtn(String trustState, bool isTrusted,
      Map<String, dynamic> peer, String titleText, ThemeData theme) {
    if (trustState == 'blocked') {
      final label = 'Unblock';
      final icon = Icons.lock_open;
      final color = theme.colorScheme.error;

      return InkWell(
        onTap: () => _handlePeerAction(
            peer: peer,
            isTrusted: isTrusted,
            trustState: trustState,
            titleText: titleText),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style: theme.textTheme.labelSmall?.copyWith(color: color)),
            ],
          ),
        ),
      );
    }

    if (trustState == 'trusted') {
      return InkWell(
        onTap: () => _handlePeerAction(
            peer: peer,
            isTrusted: isTrusted,
            trustState: trustState,
            titleText: titleText),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.more_horiz,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Text('Manage',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
        ),
      );
    }

    if (trustState == 'pairing_pending') {
      return InkWell(
        onTap: () => _handlePeerAction(
          peer: peer,
          isTrusted: isTrusted,
          trustState: trustState,
          titleText: titleText,
        ),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.error),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close, size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 4),
              Text(
                'Cancel',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Discovered state -> Verify/Pair
    return InkWell(
      onTap: () => _handlePeerAction(
          peer: peer,
          isTrusted: isTrusted,
          trustState: trustState,
          titleText: titleText),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.primary),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fingerprint, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text('Verify',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.primary)),
          ],
        ),
      ),
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
    final address = peer['address']?.toString();
    final port = peer['port'] as int?;

    if (deviceId != null && _isSelfDevice(deviceId)) {
      return;
    }
    try {
      if (deviceId != null) {
        if (trustState == 'blocked') {
          final confirmed = await _confirmTrustAction(
            title: 'Unblock device?',
            message: 'This will return $titleText to discovered state.',
            confirmLabel: 'Unblock',
          );
          if (confirmed) {
            await client.unblockPeer(deviceId);
            await _loadData();
          }
          return;
        } else if (trustState == 'pairing_pending') {
          final confirmed = await _confirmTrustAction(
            title: 'Cancel pairing?',
            message: 'This will drop the pending trust flow for $titleText.',
            confirmLabel: 'Cancel pairing',
          );
          if (confirmed) {
            await client.rejectPairing(deviceId);
            await _loadData();
          }
          return;
        }
      }

      if (!isTrusted) {
        if (deviceId == null && (address == null || port == null)) {
          return;
        }
        if (deviceId != null) {
          assert(
            !_isSelfDevice(deviceId),
            'TrustedDevicesScreen attempted to open PairingScreen for self deviceId=$deviceId',
          );
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Provider<JsonRpcRiftClient>.value(
              value: client,
              child: PairingScreen(
                initialDeviceId: deviceId,
                initialEndpointAddress: deviceId == null ? address : null,
                initialEndpointPort: deviceId == null ? port : null,
                initialDisplayName: titleText,
                autoStart: true,
              ),
            ),
          ),
        );
        await _loadData();
        return;
      } else {
        final isOnline = peer['presence'] == 'online';
        final detailResult =
            await Navigator.of(context).push<Map<String, dynamic>>(
          MaterialPageRoute<Map<String, dynamic>>(
            builder: (_) => DeviceDetailScreen(
              peer: peer,
              isOnline: isOnline,
            ),
          ),
        );
        await _loadData();
        if (!mounted || detailResult == null) {
          return;
        }

        if (detailResult['action'] == 'forgotten' && deviceId != null) {
          final forgottenDisplayName =
              detailResult['displayName']?.toString() ?? titleText;
          RiftSnackbar.show(
            context: context,
            message: '$forgottenDisplayName removed.',
            type: RiftSnackbarType.info,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: JsonRpcRiftClient.formatDisplayError(e),
        type: RiftSnackbarType.error,
      );
    }
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 192,
          height: 192,
          margin: const EdgeInsets.only(bottom: 32),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.surfaceContainerLowest,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Center(
            child: Icon(
              Icons.devices,
              size: 72,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        Text(
          'Chưa có thiết bị nào.',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Mở Rift trên thiết bị khác để bắt đầu.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Sẵn sàng kết nối qua Wi-Fi',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasTrustedPeers = _trustedPeers.any(
      (peer) => peer is Map && peer['trustState']?.toString() == 'trusted',
    );
    final discoveryLabel = _isDiscovering
        ? (hasTrustedPeers ? 'Stop Adding' : 'Stop Discovery')
        : (hasTrustedPeers ? 'Add Devices' : 'Discover Devices');
    final discoveryIcon = _isTogglingDiscovery
        ? null
        : Icon(
            _isDiscovering
                ? Icons.search_off
                : (hasTrustedPeers ? Icons.person_add_alt_1 : Icons.search),
          );
    return Scaffold(
      body: _error != null && _trustedPeers.isEmpty && _discoveredPeers.isEmpty
          ? Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text('Error loading devices: $_error',
                      style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                      onPressed: _loadData, child: const Text('Retry'))
                ]))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: (_trustedPeers.isEmpty &&
                      (!_isDiscovering || _discoveredPeers.isEmpty))
                  ? LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: ConstrainedBox(
                          constraints:
                              BoxConstraints(minHeight: constraints.maxHeight),
                          child: Column(
                            children: [
                              const SizedBox(height: 16),
                              _buildLocalDeviceCard(),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16.0),
                                child: _buildEmptyState(theme),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      children: [
                        if (_localDeviceInfo != null) _buildLocalDeviceCard(),
                        if (_trustedPeers.isNotEmpty)
                          ..._trustedPeers.map((p) => _buildPeerCard(p, true)),
                        if (_isDiscovering && _discoveredPeers.isNotEmpty)
                          ..._discoveredPeers
                              .map((p) => _buildPeerCard(p, false)),
                        const SizedBox(height: 80), // Fab spacing
                      ],
                    ),
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'pairByIpFab',
            onPressed: _showManualPairDialog,
            backgroundColor: theme.colorScheme.secondaryContainer,
            foregroundColor: theme.colorScheme.onSecondaryContainer,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            icon: const Icon(Icons.router),
            label: Text(
              'Pair by IP',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'discoverFab',
            onPressed: _isTogglingDiscovery ? null : _toggleDiscovery,
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            icon: _isTogglingDiscovery
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onPrimaryContainer))
                : discoveryIcon,
            label: Text(discoveryLabel,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
          ),
        ],
      ),
    );
  }
}
