import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/media_playback/artwork_palette.dart';
import '../src/media_playback/playback_presentation.dart';
import 'pairing_screen.dart';
import 'device_detail_screen.dart';
import '../widgets/rift_snackbar.dart';
import '../src/ui/app_shell.dart';
import '../src/ui/motion.dart';
import '../src/platform/notification_route.dart';
import '../widgets/bubble_background.dart';
import '../widgets/device_hub/device_hub_view.dart';
import '../widgets/device_hub/device_orbit_motion_state.dart';
import '../widgets/device_hub/device_orbit_scene.dart';
import '../widgets/device_hub/nearby_pairing_success.dart';
import '../widgets/device_hub/nearby_peer_focus.dart';
import '../widgets/device_hub/orbit_peer_presentation.dart';
import '../src/ui/theme.dart';

class TrustedDevicesScreen extends StatefulWidget {
  const TrustedDevicesScreen({super.key});

  @override
  State<TrustedDevicesScreen> createState() => _TrustedDevicesScreenState();
}

class _TrustedDevicesScreenState extends State<TrustedDevicesScreen>
    with TickerProviderStateMixin {
  static const Duration _presenceRefreshInterval = Duration(seconds: 5);
  static final bool _enableContinuousDiscoveryAnimation =
      !Platform.environment.containsKey('FLUTTER_TEST');
  static final bool _enableContinuousOrbitAnimation =
      !Platform.environment.containsKey('FLUTTER_TEST');

  String? _localDeviceId;
  String? _selectedDeviceId;
  String? _selectedNearbyDeviceId;
  Map<String, dynamic>? _desktopPairingTarget;
  String? _desktopPairingSuccessDeviceId;
  String? _recentlyPairedDeviceId;
  DeviceHubMode _hubMode = DeviceHubMode.trusted;
  final Set<String> _interactingOrbitPeers = <String>{};
  bool _orbitHasKeyboardFocus = false;
  bool _orbitMembershipTransitioning = false;
  bool _reducedMotion = false;
  Map<String, dynamic>? _localDeviceInfo;
  bool _isDiscovering = false;
  List<dynamic> _trustedPeers = [];
  List<dynamic> _discoveredPeers = [];
  final Map<String, Map<String, dynamic>> _playbacksByKey =
      <String, Map<String, dynamic>>{};
  final PlaybackArtworkCache _playbackArtworkCache = PlaybackArtworkCache();
  final Map<String, MediaArtwork> _artworkByPlaybackKey =
      <String, MediaArtwork>{};
  final Map<String, Color> _pendingAccentFallbackByPlaybackKey =
      <String, Color>{};
  final ArtworkAccentCache _artworkAccentCache = ArtworkAccentCache();
  final List<({bool removed, Map<String, dynamic> playback})>
      _playbackMutationsDuringLoad = [];
  bool _isLoadingPlayback = false;
  String? _error;
  bool _isLoadingData = false;
  bool _reloadQueued = false;
  bool _autoDiscoveryAttempted = false;
  bool _discoveryExplicitlyDisabled = false;
  bool _showManualConnection = false;
  bool _highlightNearbySection = false;
  bool _isNearbyVisible = false;
  bool _nearbyVisibilityCheckScheduled = false;
  final GlobalKey _nearbySectionKey = GlobalKey();
  final FocusNode _nearbySectionFocusNode = FocusNode();
  final FocusNode _manualInputFocusNode = FocusNode();
  final TextEditingController _manualInputController = TextEditingController();
  final ScrollController _mobileScrollController = ScrollController();

  StreamSubscription? _discoverySub;
  StreamSubscription? _peerLostSub;
  StreamSubscription? _trustSub;
  StreamSubscription? _pairingCompleteSub;
  StreamSubscription<Map<String, dynamic>>? _mediaPostedSub;
  StreamSubscription<Map<String, dynamic>>? _mediaUpdatedSub;
  StreamSubscription<Map<String, dynamic>>? _mediaRemovedSub;
  StreamSubscription<bool>? _connectionSub;
  Timer? _reloadDebounce;
  Timer? _fullReloadThrottle;
  Timer? _presenceRefreshTimer;
  Timer? _nearbyHighlightTimer;
  late final AnimationController _pulseController;
  late final AnimationController _bubbleController;
  late final AnimationController _spinController;
  late final AnimationController _orbitController;

  bool get _isRouteCurrent {
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _bubbleController =
        AnimationController(vsync: this, duration: const Duration(seconds: 6));
    _spinController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 120),
    );
    _mobileScrollController.addListener(_scheduleNearbyVisibilityCheck);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupListeners();
      _loadData();
      _loadPlaybackState();
      _syncOrbitAnimation();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _bubbleController.dispose();
    _spinController.dispose();
    _orbitController.dispose();
    _reloadDebounce?.cancel();
    _fullReloadThrottle?.cancel();
    _presenceRefreshTimer?.cancel();
    _nearbyHighlightTimer?.cancel();
    _nearbySectionFocusNode.dispose();
    _manualInputFocusNode.dispose();
    _manualInputController.dispose();
    _mobileScrollController.dispose();
    _discoverySub?.cancel();
    _peerLostSub?.cancel();
    _trustSub?.cancel();
    _pairingCompleteSub?.cancel();
    _mediaPostedSub?.cancel();
    _mediaUpdatedSub?.cancel();
    _mediaRemovedSub?.cancel();
    _connectionSub?.cancel();
    super.dispose();
  }

  void _setupListeners() {
    final client = context.read<JsonRpcRiftClient>();
    _discoverySub = client.onPeerDiscovered.listen(_handlePeerDiscovered);
    _peerLostSub = client.onPeerLost.listen(_handlePeerLost);
    _trustSub = client.onTrustChanged.listen(_handleTrustChanged);
    _pairingCompleteSub =
        client.onPairingComplete.listen(_handlePairingComplete);
    _mediaPostedSub = client.onMediaPlaybackPosted.listen(_upsertPlayback);
    _mediaUpdatedSub = client.onMediaPlaybackUpdated.listen(_upsertPlayback);
    _mediaRemovedSub = client.onMediaPlaybackRemoved.listen(_removePlayback);
    _connectionSub = client.onConnectionChanged.listen((isConnected) {
      if (!mounted) return;
      if (isConnected) {
        _loadData();
        _loadPlaybackState();
      } else if (_playbacksByKey.isNotEmpty ||
          _artworkByPlaybackKey.isNotEmpty) {
        setState(() {
          _playbacksByKey.clear();
          _playbackArtworkCache.clear();
          _artworkByPlaybackKey.clear();
          _pendingAccentFallbackByPlaybackKey.clear();
        });
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

    _scheduleFullReloadThrottled();
  }

  void _handlePeerLost(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString();
    final instanceId = event['instanceId']?.toString();
    if ((deviceId == null || deviceId.isEmpty) &&
        (instanceId == null || instanceId.isEmpty)) {
      return;
    }
    if (!mounted) return;

    setState(() {
      _discoveredPeers = _discoveredPeers.where((p) {
        if (p is! Map) return true;
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

    setState(() {
      if (newState == 'trusted' || newState == 'blocked') {
        _discoveredPeers = _discoveredPeers
            .where((p) => !(p is Map && p['deviceId']?.toString() == deviceId))
            .toList(growable: false);
      }
    });

    _scheduleFullReloadThrottled();
  }

  void _handlePairingComplete(Map<String, dynamic> event) {
    _scheduleFullReloadThrottled();
  }

  Future<void> _loadPlaybackState() async {
    if (!mounted || _isLoadingPlayback) return;
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) return;

    _isLoadingPlayback = true;
    _playbackMutationsDuringLoad.clear();
    try {
      final result = await client.listMediaPlayback();
      if (!mounted || !client.isConnected || result is! Map) return;
      final loaded = <String, Map<String, dynamic>>{};
      for (final item in List<dynamic>.from(
        result['playbacks'] ?? const <dynamic>[],
      )) {
        if (item is! Map) continue;
        final playback = Map<String, dynamic>.from(item);
        final key = mediaPlaybackKey(playback);
        if (key != null) loaded[key] = playback;
      }
      for (final mutation in _playbackMutationsDuringLoad) {
        final key = mediaPlaybackKey(mutation.playback);
        if (key == null) continue;
        if (mutation.removed) {
          loaded.remove(key);
        } else {
          loaded[key] = mutation.playback;
        }
      }
      final loadedArtwork = <String, MediaArtwork>{};
      for (final entry in loaded.entries) {
        final artwork =
            _playbackArtworkCache.resolve(entry.key, entry.value['artwork']);
        if (artwork != null) loadedArtwork[entry.key] = artwork;
      }
      _playbackArtworkCache.retainOnly(loaded.keys);
      setState(() {
        _playbacksByKey
          ..clear()
          ..addAll(loaded);
        _artworkByPlaybackKey
          ..clear()
          ..addAll(loadedArtwork);
        _pendingAccentFallbackByPlaybackKey.clear();
      });
      for (final artwork in loadedArtwork.values) {
        unawaited(_resolveArtworkAccent(artwork));
      }
    } catch (_) {
      // Device presentation remains usable when media state is unavailable.
    } finally {
      _isLoadingPlayback = false;
      _playbackMutationsDuringLoad.clear();
    }
  }

  void _upsertPlayback(Map<String, dynamic> event) {
    final playback = Map<String, dynamic>.from(event);
    final key = mediaPlaybackKey(playback);
    if (key == null || !mounted) return;
    if (_isLoadingPlayback) {
      _playbackMutationsDuringLoad.add((removed: false, playback: playback));
    }
    final sourceDeviceId = playback['sourceDeviceId']?.toString() ?? '';
    final previousDeviceAccent =
        _mediaPlaybackForDevice(sourceDeviceId)?.accentColor;
    final artwork = _playbackArtworkCache.resolve(key, playback['artwork']);
    final resolvedAccent = artwork == null
        ? null
        : _artworkAccentCache.accentFor(artwork.identity);
    setState(() {
      _playbacksByKey[key] = playback;
      if (artwork == null) {
        _artworkByPlaybackKey.remove(key);
        _pendingAccentFallbackByPlaybackKey.remove(key);
      } else {
        _artworkByPlaybackKey[key] = artwork;
        if (resolvedAccent == null && previousDeviceAccent != null) {
          _pendingAccentFallbackByPlaybackKey[key] = previousDeviceAccent;
        } else {
          _pendingAccentFallbackByPlaybackKey.remove(key);
        }
      }
    });
    if (artwork != null) unawaited(_resolveArtworkAccent(artwork));
  }

  void _removePlayback(Map<String, dynamic> event) {
    final playback = Map<String, dynamic>.from(event);
    final key = mediaPlaybackKey(playback);
    if (key == null || !mounted) return;
    if (_isLoadingPlayback) {
      _playbackMutationsDuringLoad.add((removed: true, playback: playback));
    }
    _playbackArtworkCache.remove(key);
    if (_playbacksByKey.containsKey(key) ||
        _artworkByPlaybackKey.containsKey(key) ||
        _pendingAccentFallbackByPlaybackKey.containsKey(key)) {
      setState(() {
        _playbacksByKey.remove(key);
        _artworkByPlaybackKey.remove(key);
        _pendingAccentFallbackByPlaybackKey.remove(key);
      });
    }
  }

  Future<void> _resolveArtworkAccent(MediaArtwork artwork) async {
    final previousAccent = _artworkAccentCache.accentFor(artwork.identity);
    final accent = await _artworkAccentCache.resolve(artwork);
    if (!mounted) return;
    final visibleKeys = _artworkByPlaybackKey.entries
        .where((entry) => entry.value.identity == artwork.identity)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (visibleKeys.isEmpty) return;
    final hadFallback = visibleKeys.any(
      _pendingAccentFallbackByPlaybackKey.containsKey,
    );
    if (hadFallback || accent != previousAccent) {
      setState(() {
        for (final key in visibleKeys) {
          _pendingAccentFallbackByPlaybackKey.remove(key);
        }
      });
    }
  }

  MediaPlaybackPresentation? _mediaPlaybackForDevice(String deviceId) {
    final playback = selectCurrentPlaybackForDevice(
      _playbacksByKey.values,
      deviceId,
    );
    if (playback == null) return null;
    final key = mediaPlaybackKey(playback);
    final artwork = key == null ? null : _artworkByPlaybackKey[key];
    return MediaPlaybackPresentation.fromRecord(
      playback,
      artworkBytes: artwork?.bytes,
      artworkIdentity: artwork?.identity,
      accentColor: artwork == null
          ? null
          : (_artworkAccentCache.accentFor(artwork.identity) ??
              (key == null ? null : _pendingAccentFallbackByPlaybackKey[key])),
    );
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

    if (_presenceRefreshTimer != null) return;

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
    _reducedMotion = RiftMotion.reducedMotionOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPresenceRefreshLoop();
      _syncPulseAnimation();
      _syncOrbitAnimation();
    });
  }

  void _syncOrbitAnimation() {
    if (!mounted) return;
    final motionState = DeviceOrbitMotionState(
      reducedMotion: _reducedMotion,
      hasFocusedPeer: _selectedDeviceId != null ||
          _selectedNearbyDeviceId != null ||
          _desktopPairingTarget != null,
      hasKeyboardFocus: _orbitHasKeyboardFocus,
      interactingPeerCount: _interactingOrbitPeers.length,
      membershipTransitioning: _orbitMembershipTransitioning,
    );
    final shouldAnimate =
        _enableContinuousOrbitAnimation && !motionState.isPaused;
    if (shouldAnimate) {
      if (!_orbitController.isAnimating) {
        _orbitController.repeat();
      }
    } else {
      _orbitController.stop();
    }
  }

  void _handleOrbitPeerInteraction(String deviceId, bool interacting) {
    if (interacting) {
      _interactingOrbitPeers.add(deviceId);
    } else {
      _interactingOrbitPeers.remove(deviceId);
    }
    _syncOrbitAnimation();
  }

  void _handleOrbitFocusChanged(bool focused) {
    _orbitHasKeyboardFocus = focused;
    _syncOrbitAnimation();
  }

  void _handleOrbitMembershipTransitionChanged(bool transitioning) {
    _orbitMembershipTransitioning = transitioning;
    _syncOrbitAnimation();
  }

  void _setHubMode(DeviceHubMode mode) {
    if (_hubMode == mode || _desktopPairingTarget != null) return;
    setState(() {
      _hubMode = mode;
      _selectedDeviceId = null;
      _selectedNearbyDeviceId = null;
      _interactingOrbitPeers.clear();
      _orbitHasKeyboardFocus = false;
      _orbitMembershipTransitioning = false;
    });
    _syncOrbitAnimation();
  }

  void _closePeerFocus() {
    setState(() {
      _selectedDeviceId = null;
      _selectedNearbyDeviceId = null;
      _desktopPairingTarget = null;
      _desktopPairingSuccessDeviceId = null;
      _interactingOrbitPeers.clear();
      _orbitHasKeyboardFocus = false;
    });
    _syncOrbitAnimation();
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

      if (!client.isConnected) {
        setState(() {
          _trustedPeers = [];
          _discoveredPeers = [];
          _localDeviceInfo = null;
          _selectedDeviceId = null;
          _selectedNearbyDeviceId = null;
          _desktopPairingTarget = null;
          _desktopPairingSuccessDeviceId = null;
          _recentlyPairedDeviceId = null;
          _isDiscovering = false;
          _error = 'Daemon not connected';
        });
        _syncPulseAnimation();
        _syncOrbitAnimation();
        _syncPresenceRefreshLoop();
        return;
      }

      final deviceInfo = await client.getDeviceInfo() as Map;
      final trustedResult = await client.listTrustedPeers();
      final discoveredResult = await client.listDiscoveredPeers();
      final localDeviceId = deviceInfo['deviceId']?.toString();
      final rawDiscoveredPeers =
          List<dynamic>.from(discoveredResult['peers'] ?? const []);
      final trustedPeers = _enrichTrustedPeersFromDiscovery(
        trustedPeers: List<dynamic>.from(
          trustedResult['peers'] ?? const [],
        ),
        discoveredPeers: rawDiscoveredPeers,
      );
      final discoveredPeers = _filterDiscoverablePeers(
        trustedPeers: trustedPeers,
        discoveredPeers: rawDiscoveredPeers,
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

          if (_selectedDeviceId != null &&
              !trustedPeers.any((peer) =>
                  peer is Map &&
                  peer['deviceId']?.toString() == _selectedDeviceId &&
                  peer['trustState']?.toString() == 'trusted')) {
            _selectedDeviceId = null;
          }
          if (_desktopPairingTarget == null &&
              _selectedNearbyDeviceId != null &&
              !discoveredPeers.any((peer) =>
                  peer is Map &&
                  peer['deviceId']?.toString() == _selectedNearbyDeviceId)) {
            _selectedNearbyDeviceId = null;
          }
        });
        _syncPulseAnimation();
        _syncOrbitAnimation();
      }
      if (!isDiscovering) {
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

  List<dynamic> _enrichTrustedPeersFromDiscovery({
    required List<dynamic> trustedPeers,
    required List<dynamic> discoveredPeers,
  }) {
    final discoveredByDeviceId = <String, Map<String, dynamic>>{};
    for (final peer in discoveredPeers.whereType<Map>()) {
      final deviceId = peer['deviceId']?.toString();
      if (deviceId == null || deviceId.isEmpty) continue;
      discoveredByDeviceId[deviceId] = Map<String, dynamic>.from(peer);
    }

    return trustedPeers.map((peer) {
      if (peer is! Map) return peer;
      final enriched = Map<String, dynamic>.from(peer);
      final deviceId = enriched['deviceId']?.toString();
      final discovered = discoveredByDeviceId[deviceId];
      if (discovered == null) return enriched;

      final displayName = enriched['displayName']?.toString().trim() ?? '';
      if (displayName.isEmpty) {
        final discoveredName =
            discovered['displayName']?.toString().trim() ?? '';
        if (discoveredName.isNotEmpty) {
          enriched['displayName'] = discoveredName;
        }
      }

      final platform = enriched['platform']?.toString().trim() ?? '';
      if (platform.isEmpty || platform == 'unknown') {
        final discoveredPlatform =
            discovered['platform']?.toString().trim() ?? '';
        if (discoveredPlatform.isNotEmpty) {
          enriched['platform'] = discoveredPlatform;
        }
      }
      return enriched;
    }).toList();
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
        _isDiscovering ||
        _discoveryExplicitlyDisabled) {
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
        _syncPulseAnimation();
      }
      _scheduleReload();
    } catch (_) {
      _autoDiscoveryAttempted = false;
    }
  }

  Future<void> _toggleDiscovery(bool value) async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      if (value) {
        await client.startDiscovery();
      } else {
        await client.stopDiscovery();
      }
      if (mounted) {
        setState(() {
          _isDiscovering = value;
          _discoveryExplicitlyDisabled = !value;
          _error = null;
        });
        _syncPulseAnimation();
      }
      _scheduleReload();
    } catch (e) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: JsonRpcRiftClient.formatDisplayError(e),
          type: RiftSnackbarType.error,
        );
      }
    }
  }

  Future<bool> _confirmTrustAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final theme = Theme.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: Text(title,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          content: Text(message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4))),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4))),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Widget _buildLocalDeviceCardHtml(ThemeData theme) {
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

    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    final selfId = deviceId.isNotEmpty ? deviceId : 'self';
    final isSelected = isDesktop &&
        (_selectedDeviceId == 'self' || _selectedDeviceId == selfId);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.12)
          : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('local-device-card'),
        onTap: () => _showLocalDeviceDetails(localDeviceInfo),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(8)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: [
                              Icon(_platformIcon(platform),
                                  size: 20, color: theme.colorScheme.primary),
                              Positioned(
                                top: -4,
                                right: -4,
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      titleText,
                                      style:
                                          theme.textTheme.titleMedium?.copyWith(
                                        color: theme.colorScheme.onSurface,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(Icons.verified,
                                      size: 18,
                                      color: theme.colorScheme.primary),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  children: [
                                    Icon(Icons.fingerprint,
                                        size: 14,
                                        color: theme
                                            .colorScheme.onSurfaceVariant
                                            .withValues(alpha: 0.7)),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        _localDeviceId != null
                                            ? (_localDeviceId!.length > 20
                                                ? '${_localDeviceId!.substring(0, 20)}...'
                                                : _localDeviceId!)
                                            : 'Loading fingerprint...',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                                fontFamily: 'monospace',
                                                color: theme.colorScheme
                                                    .onSurfaceVariant
                                                    .withValues(alpha: 0.7)),
                                        overflow: TextOverflow.ellipsis,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLocalDeviceDetails(
    Map<String, dynamic> deviceInfo,
  ) async {
    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    final selfDeviceId = deviceInfo['deviceId']?.toString() ?? 'self';

    if (isDesktop) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return Dialog(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: 760,
              height: MediaQuery.sizeOf(dialogContext).height * 0.82,
              child: DeviceDetailScreen(
                key: ValueKey(selfDeviceId),
                peer: deviceInfo,
                isOnline: true,
                isSelf: true,
                onClose: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          );
        },
      );
      if (mounted) await _loadData();
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DeviceDetailScreen(
          key: ValueKey(selfDeviceId),
          peer: deviceInfo,
          isOnline: true,
          isSelf: true,
        ),
      ),
    );
    await _loadData();
  }

  Widget _buildPeerCardHtml(
      Map<String, dynamic> peer, bool isTrusted, ThemeData theme) {
    if (peer['trustState'] == 'blocked') return const SizedBox.shrink();

    final isOnline = peer['presence'] == 'online';
    final trustState = peer['trustState']?.toString() ?? 'trusted';

    final String deviceIdStr = peer['deviceId']?.toString() ?? '';
    final String rawDisplayName = peer['displayName']?.toString() ?? '';
    final String peerPlatform = peer['platform']?.toString() ?? 'unknown';
    final String shortId =
        deviceIdStr.length > 16 ? deviceIdStr.substring(0, 16) : deviceIdStr;
    final String titleText = rawDisplayName.isNotEmpty
        ? rawDisplayName
        : (shortId.isNotEmpty ? shortId : 'Unknown Device');
    final String statusText = trustState == 'pairing_pending'
        ? 'PENDING'
        : (isOnline ? 'ONLINE' : 'OFFLINE');

    final bool isPending = trustState == 'pairing_pending';

    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    final isSelected =
        isDesktop && deviceIdStr.isNotEmpty && _selectedDeviceId == deviceIdStr;

    return InkWell(
      key: ValueKey('trusted-peer-card-$deviceIdStr'),
      onTap: () => _handlePeerAction(
          peer: peer,
          isTrusted: isTrusted,
          trustState: trustState,
          titleText: titleText),
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: RiftMotion.durationOf(context, RiftMotion.normal),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.12)
              : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Icon(_platformIcon(peerPlatform),
                      size: 20, color: theme.colorScheme.primary),
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: isOnline
                            ? const Color(0xFF10B981)
                            : theme.colorScheme.outlineVariant,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    titleText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    statusText,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isPending)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiaryContainer
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.hourglass_empty,
                            size: 14, color: theme.colorScheme.tertiary),
                        const SizedBox(width: 4),
                        Text('PENDING',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.tertiary)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  TextButton(
                    onPressed: () => _handlePeerAction(
                      peer: peer,
                      isTrusted: true,
                      trustState: trustState,
                      titleText: titleText,
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                      foregroundColor: theme.colorScheme.tertiary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              )
            else
              Icon(
                Icons.chevron_right,
                size: 20,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveredCardHtml(Map<String, dynamic> peer, ThemeData theme) {
    final String deviceIdStr = peer['deviceId']?.toString() ?? '';
    final String rawDisplayName = peer['displayName']?.toString() ?? '';
    final String peerPlatform = peer['platform']?.toString() ?? 'unknown';
    final String shortId =
        deviceIdStr.length > 16 ? deviceIdStr.substring(0, 16) : deviceIdStr;
    final String titleText = rawDisplayName.isNotEmpty
        ? rawDisplayName
        : (shortId.isNotEmpty ? shortId : 'Unknown Device');
    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    final isSelected =
        isDesktop && deviceIdStr.isNotEmpty && _selectedDeviceId == deviceIdStr;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.12)
            : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_platformIcon(peerPlatform),
                size: 20, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(titleText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('Local Network',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => _handlePeerAction(
              peer: peer,
              isTrusted: false,
              trustState: 'discovered',
              titleText: titleText,
            ),
            icon: const Icon(Icons.link, size: 16),
            label: const Text('Pair'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRestrictedCardHtml(Map<String, dynamic> peer, ThemeData theme) {
    final String deviceIdStr = peer['deviceId']?.toString() ?? '';
    final String rawDisplayName = peer['displayName']?.toString() ?? '';
    final String shortId =
        deviceIdStr.length > 16 ? deviceIdStr.substring(0, 16) : deviceIdStr;
    final String titleText = rawDisplayName.isNotEmpty
        ? rawDisplayName
        : (shortId.isNotEmpty ? shortId : 'Unknown Device');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.block,
                      size: 20, color: theme.colorScheme.error),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titleText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: theme.colorScheme.outlineVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text('Blocked',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: () => _handlePeerAction(
                peer: peer,
                isTrusted: true,
                trustState: 'blocked',
                titleText: titleText),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
            ),
            child: const Text('Manage'),
          ),
        ],
      ),
    );
  }

  void _showActivityForPeer({
    required String route,
    required String deviceId,
    required String displayName,
  }) {
    context.findAncestorStateOfType<AppShellState>()?.showActivityForDevice(
          route: route,
          deviceId: deviceId,
          displayName: displayName,
        );
  }

  DeviceDetailScreen _buildTrustedPeerDetail({
    required Map<String, dynamic> peer,
    required bool isOnline,
    required VoidCallback? onClose,
  }) {
    final deviceId = peer['deviceId']?.toString() ?? '';
    final displayName = peer['displayName']?.toString() ?? deviceId;
    final canOpenActivity = onClose != null && deviceId.isNotEmpty;
    return DeviceDetailScreen(
      key: ValueKey(deviceId.isNotEmpty ? deviceId : displayName),
      peer: peer,
      isOnline: isOnline,
      mediaPlayback: _mediaPlaybackForDevice(deviceId),
      onClose: onClose,
      onOpenClipboardActivity: canOpenActivity
          ? () => _showActivityForPeer(
                route: NotificationRoute.historyClipboard,
                deviceId: deviceId,
                displayName: displayName,
              )
          : null,
      onSendFile: canOpenActivity
          ? () => _showActivityForPeer(
                route: NotificationRoute.historySend,
                deviceId: deviceId,
                displayName: displayName,
              )
          : null,
      onViewTransferActivity: canOpenActivity
          ? () => _showActivityForPeer(
                route: NotificationRoute.historyTransferActivity,
                deviceId: deviceId,
                displayName: displayName,
              )
          : null,
    );
  }

  void _beginDesktopPairing(
    Map<String, dynamic> peer,
    String displayName,
  ) {
    final target = Map<String, dynamic>.from(peer);
    target['displayName'] = displayName;
    setState(() {
      _hubMode = DeviceHubMode.nearby;
      _selectedDeviceId = null;
      _selectedNearbyDeviceId = target['deviceId']?.toString();
      _desktopPairingTarget = target;
      _desktopPairingSuccessDeviceId = null;
      _interactingOrbitPeers.clear();
      _orbitHasKeyboardFocus = false;
    });
    _syncOrbitAnimation();
  }

  void _returnFromDesktopPairing() {
    final targetDeviceId = _desktopPairingTarget?['deviceId']?.toString();
    final remainsNearby = targetDeviceId != null &&
        _nearbyOrbitPeers.any(
          (peer) => peer['deviceId']?.toString() == targetDeviceId,
        );
    setState(() {
      _desktopPairingTarget = null;
      _desktopPairingSuccessDeviceId = null;
      _selectedNearbyDeviceId = remainsNearby ? targetDeviceId : null;
    });
    _syncOrbitAnimation();
  }

  Future<void> _completeDesktopPairing(String deviceId) async {
    if (_desktopPairingTarget == null ||
        _desktopPairingSuccessDeviceId != null) {
      return;
    }
    setState(() {
      _desktopPairingSuccessDeviceId = deviceId;
      _interactingOrbitPeers.clear();
      _orbitHasKeyboardFocus = false;
    });
    _syncOrbitAnimation();

    await Future<void>.delayed(
      _reducedMotion ? RiftMotion.fast : RiftMotion.scene,
    );
    if (!mounted || _desktopPairingSuccessDeviceId != deviceId) return;

    await _loadData();
    if (!mounted || _desktopPairingSuccessDeviceId != deviceId) return;
    setState(() {
      _desktopPairingTarget = null;
      _desktopPairingSuccessDeviceId = null;
      _recentlyPairedDeviceId = deviceId;
      _hubMode = DeviceHubMode.trusted;
      _selectedDeviceId = null;
      _selectedNearbyDeviceId = null;
      _interactingOrbitPeers.clear();
      _orbitHasKeyboardFocus = false;
    });
    _syncOrbitAnimation();
  }

  void _handleRecentlyPairedAnimationCompleted(String deviceId) {
    if (!mounted || _recentlyPairedDeviceId != deviceId) return;
    setState(() {
      _recentlyPairedDeviceId = null;
    });
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
        }
      }

      if (!isTrusted) {
        if (deviceId == null && (address == null || port == null)) {
          return;
        }
        if (MediaQuery.sizeOf(context).width >= 1024) {
          _beginDesktopPairing(peer, titleText);
          return;
        }
        final targetId = deviceId ?? address ?? titleText;
        final pairingScreen = deviceId != null
            ? PairingScreen.forDiscoveredPeer(
                key: ValueKey('pairing-$targetId'),
                deviceId: deviceId,
                displayName: titleText,
              )
            : PairingScreen.forEndpoint(
                key: ValueKey('pairing-$targetId'),
                address: address!,
                port: port!,
                displayName: titleText,
              );

        final result = await showDialog<dynamic>(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.black.withValues(alpha: 0.4),
          builder: (_) => Provider<JsonRpcRiftClient>.value(
            value: client,
            child: pairingScreen,
          ),
        );
        await _loadData();
        if (mounted) {
          if (result == 'history') {
            final appShellState =
                context.findAncestorStateOfType<AppShellState>();
            appShellState?.showHistoryRoute(NotificationRoute.historyClipboard);
          } else if (result == 'devices') {
            final appShellState =
                context.findAncestorStateOfType<AppShellState>();
            appShellState?.showRoute(NotificationRoute.devices);
          }
        }
        return;
      } else if (trustState == 'pairing_pending') {
        final confirmed = await _confirmTrustAction(
          title: 'Cancel pairing?',
          message: 'This will stop the pairing flow for $titleText.',
          confirmLabel: 'Cancel pairing',
        );
        if (confirmed && deviceId != null) {
          await client.rejectPairing(deviceId);
          await _loadData();
        }
        return;
      } else {
        final isOnline = peer['presence'] == 'online';
        final isDesktop = MediaQuery.of(context).size.width >= 1024;
        final targetId = deviceId ?? titleText;

        if (isDesktop) {
          setState(() {
            _hubMode = DeviceHubMode.trusted;
            _selectedDeviceId = targetId;
            _selectedNearbyDeviceId = null;
          });
          _syncOrbitAnimation();
          return;
        }

        final detailResult =
            await Navigator.of(context).push<Map<String, dynamic>>(
          MaterialPageRoute<Map<String, dynamic>>(
            builder: (_) => DeviceDetailScreen(
              key: ValueKey(targetId),
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

  String _localPlatform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  Widget _buildUnifiedLayout(ThemeData theme, BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('This Device',
            style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        _buildLocalDeviceCardHtml(theme),
        const SizedBox(height: 16),
        if (_trustedPeers
            .any((p) => p is Map && p['trustState'] == 'pairing_pending')) ...[
          Text('Pairing Pending',
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Column(
            children: _trustedPeers
                .where((p) => p is Map && p['trustState'] == 'pairing_pending')
                .map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildPeerCardHtml(
                        p as Map<String, dynamic>, false, theme)))
                .toList(),
          ),
          const SizedBox(height: 16),
        ],
        if (_trustedPeers
            .any((p) => p is Map && p['trustState'] == 'trusted')) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                  child: Text('Trusted Peers',
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                    '${_trustedPeers.where((p) => p is Map && p['trustState'] == 'trusted').length} Devices',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Column(
            children: _trustedPeers
                .where((p) => p is Map && p['trustState'] == 'trusted')
                .map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildPeerCardHtml(
                        p as Map<String, dynamic>, true, theme)))
                .toList(),
          ),
          const SizedBox(height: 8),
        ],
        _buildDiscoveredSection(theme),
        const SizedBox(height: 16),
        if (_trustedPeers.any((p) => p is Map && p['trustState'] == 'blocked'))
          _buildBlockedSection(theme),
      ],
    );
  }

  void _scheduleNearbyVisibilityCheck() {
    if (_nearbyVisibilityCheckScheduled || !mounted) return;
    _nearbyVisibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nearbyVisibilityCheckScheduled = false;
      if (!mounted) return;
      _updateNearbyVisibility();
    });
  }

  void _updateNearbyVisibility() {
    if (MediaQuery.sizeOf(context).width >= 1024) return;
    final nearbyContext = _nearbySectionKey.currentContext;
    final sectionBox = nearbyContext?.findRenderObject();
    final viewportBox = context.findRenderObject();
    if (sectionBox is! RenderBox || viewportBox is! RenderBox) return;

    final sectionTop = sectionBox.localToGlobal(Offset.zero).dy;
    final sectionBottom = sectionTop + sectionBox.size.height;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    final visibleTop = sectionTop > viewportTop ? sectionTop : viewportTop;
    final visibleBottom =
        sectionBottom < viewportBottom ? sectionBottom : viewportBottom;
    final visibleExtent = visibleBottom - visibleTop;
    final visibilityThreshold =
        sectionBox.size.height < 56 ? sectionBox.size.height : 56.0;
    final isVisible = visibleExtent >= visibilityThreshold;

    if (_isNearbyVisible != isVisible) {
      setState(() {
        _isNearbyVisible = isVisible;
      });
    }
  }

  void _showNearbyDevices() {
    if (!_isDiscovering) {
      unawaited(_toggleDiscovery(true));
    }

    _nearbyHighlightTimer?.cancel();
    setState(() {
      _highlightNearbySection = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nearbyContext = _nearbySectionKey.currentContext;
      if (nearbyContext != null) {
        Scrollable.ensureVisible(
          nearbyContext,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          alignment: 0.1,
        );
      }
      _nearbySectionFocusNode.requestFocus();
    });
    _nearbyHighlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() {
        _highlightNearbySection = false;
      });
    });
  }

  void _toggleManualConnection() {
    setState(() {
      _showManualConnection = !_showManualConnection;
    });
    if (_showManualConnection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _manualInputFocusNode.requestFocus();
      });
    }
  }

  Future<void> _pairManually() async {
    final input = _manualInputController.text.trim();
    if (input.isEmpty) return;

    String address = input;
    int port = 11112;

    if (input.startsWith('[')) {
      final closingIndex = input.indexOf(']');
      if (closingIndex > 0) {
        address = input.substring(1, closingIndex);
        final suffix = input.substring(closingIndex + 1);
        if (suffix.startsWith(':')) {
          port = int.tryParse(suffix.substring(1)) ?? 11112;
        }
      }
    } else {
      final lastColon = input.lastIndexOf(':');
      if (lastColon > 0 && input.indexOf(':') == lastColon) {
        address = input.substring(0, lastColon);
        port = int.tryParse(input.substring(lastColon + 1)) ?? 11112;
      }
    }

    _manualInputFocusNode.unfocus();
    await _handlePeerAction(
      peer: {'address': address, 'port': port},
      isTrusted: false,
      trustState: 'discovered',
      titleText: address,
    );
  }

  List<Map<String, dynamic>> get _trustedOrbitPeers => _trustedPeers
      .whereType<Map>()
      .where((peer) => peer['trustState']?.toString() == 'trusted')
      .map(Map<String, dynamic>.from)
      .toList(growable: false);

  List<Map<String, dynamic>> get _nearbyOrbitPeers => _discoveredPeers
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList(growable: false);

  String _displayNameFor(Map<String, dynamic> peer) {
    final displayName = peer['displayName']?.toString().trim() ?? '';
    if (displayName.isNotEmpty) return displayName;
    final deviceId = peer['deviceId']?.toString() ?? '';
    if (deviceId.isEmpty) return 'Unknown Device';
    return deviceId.length > 18 ? '${deviceId.substring(0, 18)}…' : deviceId;
  }

  OrbitPeerPresentation _orbitPresentationFor(
    Map<String, dynamic> peer, {
    bool includeMedia = false,
    OrbitPeerStatusKind? statusKind,
  }) {
    final deviceId = peer['deviceId']?.toString() ?? '';
    final media = includeMedia ? _mediaPlaybackForDevice(deviceId) : null;
    return OrbitPeerPresentation(
      deviceId: deviceId,
      displayName: _displayNameFor(peer),
      platform: peer['platform']?.toString() ?? 'unknown',
      statusKind: statusKind ??
          (peer['presence']?.toString() == 'online'
              ? OrbitPeerStatusKind.trustedOnline
              : OrbitPeerStatusKind.trustedOffline),
      accentColor: media?.accentColor,
      activity: switch (media?.playbackState) {
        null => OrbitPeerActivity.none,
        'playing' => OrbitPeerActivity.mediaPlaying,
        'buffering' => OrbitPeerActivity.mediaBuffering,
        _ => OrbitPeerActivity.mediaPaused,
      },
      mediaTitle: media?.displayTitle,
      mediaArtist:
          media != null && media.artist.isNotEmpty ? media.artist : null,
    );
  }

  Map<String, dynamic>? _peerWithId(
    Iterable<Map<String, dynamic>> peers,
    String? deviceId,
  ) {
    if (deviceId == null) return null;
    for (final peer in peers) {
      if (peer['deviceId']?.toString() == deviceId) return peer;
    }
    return null;
  }

  Widget _buildTrustedDesktopScene() {
    final peers = _trustedOrbitPeers;
    final selectedPeer = _peerWithId(peers, _selectedDeviceId);
    final duration = RiftMotion.durationOf(context, RiftMotion.normal);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: RiftMotion.enter,
      switchOutCurve: RiftMotion.exit,
      transitionBuilder: _buildFocusTransition,
      child: selectedPeer == null
          ? DeviceOrbitScene(
              key: const ValueKey('trusted-orbit-overview'),
              localDisplayName:
                  _localDeviceInfo?['displayName']?.toString() ?? 'This Device',
              localPlatform:
                  _localDeviceInfo?['platform']?.toString() ?? _localPlatform(),
              peers: peers
                  .map(
                      (peer) => _orbitPresentationFor(peer, includeMedia: true))
                  .toList(growable: false),
              phase: _orbitController,
              scanProgress: _pulseController,
              peerKeyPrefix: 'trusted-orbit-peer',
              peerSemanticRole: 'trusted device',
              onPeerSelected: (peer) {
                setState(() {
                  _selectedDeviceId = peer.deviceId;
                  _selectedNearbyDeviceId = null;
                  _interactingOrbitPeers.clear();
                  _orbitHasKeyboardFocus = false;
                });
                _syncOrbitAnimation();
              },
              onPeerInteractionChanged: _handleOrbitPeerInteraction,
              onSceneFocusChanged: _handleOrbitFocusChanged,
              onMembershipTransitionChanged:
                  _handleOrbitMembershipTransitionChanged,
              onLocalDeviceTap: _localDeviceInfo == null
                  ? null
                  : () => _showLocalDeviceDetails(_localDeviceInfo!),
              animatePeerChanges: true,
              emptyMessage: 'No trusted devices yet.',
              recentlyPairedDeviceId: _recentlyPairedDeviceId,
              onRecentlyPairedAnimationCompleted:
                  _handleRecentlyPairedAnimationCompleted,
            )
          : CallbackShortcuts(
              key: ValueKey(
                'trusted-peer-focus-${selectedPeer['deviceId']}',
              ),
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape):
                    _closePeerFocus,
              },
              child: Focus(
                autofocus: true,
                child: _buildTrustedPeerDetail(
                  peer: selectedPeer,
                  isOnline: selectedPeer['presence']?.toString() == 'online',
                  onClose: () {
                    _closePeerFocus();
                    unawaited(_loadData());
                  },
                ),
              ),
            ),
    );
  }

  Widget _buildDesktopPairingScene(Map<String, dynamic> target) {
    final deviceId = target['deviceId']?.toString();
    final displayName = _displayNameFor(target);
    final successDeviceId = _desktopPairingSuccessDeviceId;
    if (successDeviceId != null) {
      return NearbyPairingSuccess(
        key: ValueKey('nearby-pairing-success-focus-$successDeviceId'),
        deviceId: successDeviceId,
        displayName: displayName,
        platform: target['platform']?.toString() ?? 'unknown',
      );
    }
    final address = target['address']?.toString();
    final port = (target['port'] as num?)?.toInt();
    final targetKey = deviceId ?? '$address:$port';
    final pairing = deviceId != null
        ? PairingScreen.forDiscoveredPeer(
            key: ValueKey('nearby-pairing-$targetKey'),
            deviceId: deviceId,
            displayName: displayName,
            onClose: _returnFromDesktopPairing,
            onCompleted: (pairedDeviceId) =>
                unawaited(_completeDesktopPairing(pairedDeviceId)),
          )
        : PairingScreen.forEndpoint(
            key: ValueKey('nearby-pairing-$targetKey'),
            address: address!,
            port: port!,
            displayName: displayName,
            onClose: _returnFromDesktopPairing,
            onCompleted: (pairedDeviceId) =>
                unawaited(_completeDesktopPairing(pairedDeviceId)),
          );
    return KeyedSubtree(
      key: ValueKey('nearby-pairing-focus-$targetKey'),
      child: pairing,
    );
  }

  Widget _buildNearbyDesktopScene() {
    final peers = _nearbyOrbitPeers;
    final selectedPeer = _peerWithId(peers, _selectedNearbyDeviceId);
    final pairingTarget = _desktopPairingTarget;
    final duration = RiftMotion.durationOf(context, RiftMotion.normal);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: RiftMotion.enter,
      switchOutCurve: RiftMotion.exit,
      transitionBuilder: _buildFocusTransition,
      child: pairingTarget != null
          ? _buildDesktopPairingScene(pairingTarget)
          : selectedPeer == null
              ? DeviceOrbitScene(
                  key: const ValueKey('nearby-orbit-overview'),
                  localDisplayName:
                      _localDeviceInfo?['displayName']?.toString() ??
                          'This Device',
                  localPlatform: _localDeviceInfo?['platform']?.toString() ??
                      _localPlatform(),
                  peers: peers
                      .map(
                        (peer) => _orbitPresentationFor(
                          peer,
                          statusKind: OrbitPeerStatusKind.nearby,
                        ),
                      )
                      .toList(growable: false),
                  phase: _orbitController,
                  scanProgress: _pulseController,
                  peerKeyPrefix: 'nearby-orbit-peer',
                  peerSemanticRole: 'nearby device',
                  onPeerSelected: (peer) {
                    setState(() {
                      _selectedNearbyDeviceId = peer.deviceId;
                      _selectedDeviceId = null;
                      _interactingOrbitPeers.clear();
                      _orbitHasKeyboardFocus = false;
                    });
                    _syncOrbitAnimation();
                  },
                  onPeerInteractionChanged: _handleOrbitPeerInteraction,
                  onSceneFocusChanged: _handleOrbitFocusChanged,
                  onMembershipTransitionChanged:
                      _handleOrbitMembershipTransitionChanged,
                  onLocalDeviceTap: _localDeviceInfo == null
                      ? null
                      : () => _showLocalDeviceDetails(_localDeviceInfo!),
                  scanning: _isDiscovering,
                  animatePeerChanges: true,
                  emptyMessage: _isDiscovering
                      ? 'Looking for nearby devices…'
                      : 'Discovery paused',
                  emptyAction: _isDiscovering
                      ? null
                      : FilledButton.icon(
                          key: const ValueKey('nearby-start-discovery'),
                          onPressed: () => _toggleDiscovery(true),
                          icon: const Icon(Icons.radar),
                          label: const Text('Start Discovery'),
                        ),
                )
              : CallbackShortcuts(
                  key: ValueKey(
                    'nearby-peer-focus-shortcuts-${selectedPeer['deviceId']}',
                  ),
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape):
                        _closePeerFocus,
                  },
                  child: Focus(
                    autofocus: true,
                    child: NearbyPeerFocus(
                      deviceId: selectedPeer['deviceId']?.toString() ?? '',
                      displayName: _displayNameFor(selectedPeer),
                      platform:
                          selectedPeer['platform']?.toString() ?? 'unknown',
                      endpoint: _endpointFor(selectedPeer),
                      onClose: _closePeerFocus,
                      onPair: () => unawaited(
                        _handlePeerAction(
                          peer: selectedPeer,
                          isTrusted: false,
                          trustState: 'discovered',
                          titleText: _displayNameFor(selectedPeer),
                        ),
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _buildFocusTransition(Widget child, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
        child: child,
      ),
    );
  }

  String? _endpointFor(Map<String, dynamic> peer) {
    final address = peer['address']?.toString();
    if (address == null || address.isEmpty) return null;
    final port = peer['port'];
    return port is num ? '$address:${port.toInt()}' : address;
  }

  List<Widget> _buildDesktopHubActions() {
    final actions = <Widget>[];
    final pairingActive = _desktopPairingTarget != null;
    if (_hubMode == DeviceHubMode.nearby) {
      actions.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isDiscovering ? 'Scan on' : 'Scan off',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Switch(
              key: const ValueKey('desktop-discovery-switch'),
              value: _isDiscovering,
              onChanged: pairingActive ? null : _toggleDiscovery,
            ),
          ],
        ),
      );
      actions.add(
        OutlinedButton.icon(
          key: const ValueKey('desktop-manual-connect'),
          onPressed: pairingActive ? null : _showDesktopManualConnection,
          icon: const Icon(Icons.add_link, size: 18),
          label: const Text('Manual'),
        ),
      );
    }

    final managedCount = _trustedPeers.whereType<Map>().where((peer) {
      final state = peer['trustState']?.toString();
      return state == 'pairing_pending' || state == 'blocked';
    }).length;
    actions.add(
      OutlinedButton.icon(
        key: const ValueKey('desktop-device-management'),
        onPressed: pairingActive ? null : _showDesktopDeviceManagement,
        icon: const Icon(Icons.tune, size: 18),
        label: Text(managedCount == 0 ? 'Manage' : 'Manage ($managedCount)'),
      ),
    );
    return actions;
  }

  Future<void> _showDesktopManualConnection() async {
    final shouldConnect = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Connect manually'),
          content: SizedBox(
            width: 420,
            child: TextField(
              key: const ValueKey('desktop-manual-device-address'),
              controller: _manualInputController,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.of(dialogContext).pop(true),
              decoration: const InputDecoration(
                labelText: 'IP address or hostname',
                hintText: '192.168.1.50 or device.local',
                helperText:
                    'You will verify the device before it becomes trusted.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('desktop-manual-connect-button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
    if (shouldConnect == true && mounted) {
      await _pairManually();
    }
  }

  Future<void> _showDesktopDeviceManagement() async {
    final pending = _trustedPeers
        .whereType<Map>()
        .where((peer) => peer['trustState']?.toString() == 'pairing_pending')
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
    final blocked = _trustedPeers
        .whereType<Map>()
        .where((peer) => peer['trustState']?.toString() == 'blocked')
        .map(Map<String, dynamic>.from)
        .toList(growable: false);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: const Text('Device management'),
          content: SizedBox(
            width: 480,
            child: pending.isEmpty && blocked.isEmpty
                ? const Text('No pending or blocked devices.')
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (pending.isNotEmpty) ...[
                          Text('Pairing pending',
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          for (final peer in pending)
                            ListTile(
                              leading: const Icon(Icons.hourglass_empty),
                              title: Text(_displayNameFor(peer)),
                              subtitle: const Text('Pairing pending'),
                              trailing: TextButton(
                                onPressed: () {
                                  Navigator.of(dialogContext).pop();
                                  unawaited(
                                    _handlePeerAction(
                                      peer: peer,
                                      isTrusted: true,
                                      trustState: 'pairing_pending',
                                      titleText: _displayNameFor(peer),
                                    ),
                                  );
                                },
                                child: const Text('Cancel'),
                              ),
                            ),
                        ],
                        if (pending.isNotEmpty && blocked.isNotEmpty)
                          const Divider(),
                        if (blocked.isNotEmpty) ...[
                          Text('Blocked', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          for (final peer in blocked)
                            ListTile(
                              leading: Icon(Icons.block,
                                  color: theme.colorScheme.error),
                              title: Text(_displayNameFor(peer)),
                              subtitle: const Text('Blocked'),
                              trailing: TextButton(
                                onPressed: () {
                                  Navigator.of(dialogContext).pop();
                                  unawaited(
                                    _handlePeerAction(
                                      peer: peer,
                                      isTrusted: true,
                                      trustState: 'blocked',
                                      titleText: _displayNameFor(peer),
                                    ),
                                  );
                                },
                                child: const Text('Unblock'),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget? _buildDesktopErrorBanner() {
    final error = _error;
    if (error == null) return null;
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('device-hub-error'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text('Daemon Error: $error')),
          TextButton(onPressed: _loadData, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildDesktopHub() {
    return DeviceHubView(
      mode: _hubMode,
      onModeChanged: _setHubMode,
      modeSelectionEnabled: _desktopPairingTarget == null,
      trustedScene: _buildTrustedDesktopScene(),
      nearbyScene: _buildNearbyDesktopScene(),
      actions: _buildDesktopHubActions(),
      banner: _buildDesktopErrorBanner(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    if (isDesktop) return _buildDesktopHub();

    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        Text(
          'Devices Hub',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );

    _scheduleNearbyVisibilityCheck();
    final showFindDeviceAction = !_isNearbyVisible && !_showManualConnection;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      floatingActionButton: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: showFindDeviceAction
            ? FloatingActionButton.extended(
                key: const ValueKey('find-device-floating-action'),
                heroTag: 'find-device-mobile',
                onPressed: _showNearbyDevices,
                icon: const Icon(Icons.radar),
                label: const Text('Find Device'),
              )
            : const SizedBox.shrink(
                key: ValueKey('find-device-floating-action-hidden'),
              ),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: SingleChildScrollView(
          controller: _mobileScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          child: Padding(
            padding: RiftDesign.padScreenMobile,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 16),
                if (_error != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color:
                              theme.colorScheme.error.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            color: theme.colorScheme.error),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text('Daemon Error: $_error',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onErrorContainer)),
                        ),
                        TextButton(
                          onPressed: _loadData,
                          style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.error),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: _buildUnifiedLayout(theme, context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiscoveredSection(ThemeData theme) {
    final bubbleColor = theme.colorScheme.primary;
    return Focus(
      focusNode: _nearbySectionFocusNode,
      child: AnimatedContainer(
        key: _nearbySectionKey,
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _highlightNearbySection
                ? theme.colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Nearby Devices',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isDiscovering) _buildDiscoveryStatusChip(theme),
                    const SizedBox(width: 8),
                    Transform.scale(
                      scale: 0.8,
                      child: Switch.adaptive(
                        value: _isDiscovering,
                        onChanged: (value) => _toggleDiscovery(value),
                        activeTrackColor: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_discoveredPeers.isEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  key: const ValueKey('nearby-devices-list'),
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 80),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: AnimatedBuilder(
                          animation: _bubbleController,
                          builder: (context, child) {
                            return BubbleBackground(
                              progress: _bubbleController.value,
                              color: bubbleColor,
                            );
                          },
                        ),
                      ),
                      SizedBox(
                        height: 78,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              Icon(
                                _isDiscovering
                                    ? Icons.wifi_find
                                    : Icons.wifi_off,
                                size: 24,
                                color: _isDiscovering
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outlineVariant,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  _isDiscovering
                                      ? 'Looking for devices on your local network…'
                                      : 'Discovery disabled.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Column(
                key: const ValueKey('nearby-devices-list'),
                children: _discoveredPeers
                    .map((p) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildDiscoveredCardHtml(
                            p as Map<String, dynamic>, theme)))
                    .toList(),
              ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('manual-connect-toggle'),
              onPressed: _toggleManualConnection,
              icon: Icon(
                _showManualConnection ? Icons.expand_less : Icons.edit_note,
                size: 18,
              ),
              label: const Text("Can't find your device? Connect manually"),
            ),
            if (_showManualConnection) ...[
              const SizedBox(height: 4),
              Container(
                key: const ValueKey('manual-connect-panel'),
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Enter an IP address or hostname. You will still verify the device before trusting it.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final input = TextField(
                          key: const ValueKey('manual-device-address'),
                          controller: _manualInputController,
                          focusNode: _manualInputFocusNode,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _pairManually(),
                          decoration: const InputDecoration(
                            labelText: 'IP address or hostname',
                            hintText: '192.168.1.50 or device.local',
                          ),
                        );
                        final connectButton = FilledButton(
                          key: const ValueKey('manual-connect-button'),
                          onPressed: _pairManually,
                          child: const Text('Connect'),
                        );

                        if (constraints.maxWidth < 520) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              input,
                              const SizedBox(height: 12),
                              connectButton,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(child: input),
                            const SizedBox(width: 12),
                            connectButton,
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBlockedSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Blocked',
            style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ..._trustedPeers
            .where((p) => p is Map && p['trustState'] == 'blocked')
            .map((p) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildRestrictedCardHtml(
                    p as Map<String, dynamic>, theme))),
      ],
    );
  }

  void _syncPulseAnimation() {
    if (_isDiscovering &&
        _enableContinuousDiscoveryAnimation &&
        !_reducedMotion) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
      if (!_bubbleController.isAnimating) {
        _bubbleController.repeat();
      }
      if (!_spinController.isAnimating) {
        _spinController.repeat();
      }
      return;
    }

    _pulseController.stop();
    _bubbleController.stop();
    _spinController.stop();
    _pulseController.value = _isDiscovering ? 1.0 : 0.0;
    _bubbleController.value = _isDiscovering ? 0.35 : 0.0;
  }

  Widget _buildDiscoveryStatusChip(ThemeData theme) {
    if (!_isDiscovering) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RotationTransition(
            turns: _spinController,
            child: Icon(
              Icons.sync,
              size: 14,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Scanning...',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
