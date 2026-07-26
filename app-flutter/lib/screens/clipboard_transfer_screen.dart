import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../src/file_transfer/file_storage.dart';
import '../src/file_transfer/legacy_send_queue_coordinator.dart';
import '../src/file_transfer/send_queue_controller.dart';
import '../src/file_transfer/send_queue_entry.dart';
import '../src/file_transfer/send_queue_mode_coordinator.dart';
import '../src/file_transfer/send_queue_panel.dart';
import '../src/file_transfer/send_queue_summary.dart';
import '../src/file_transfer/send_queue_targeting.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/platform/macos_send_files.dart';
import '../src/platform/notification_route.dart';
import '../widgets/rift_snackbar.dart';
import '../widgets/premium_dialog.dart';

enum _HistorySection {
  clipboard,
  send,
  incomingOffers,
  transferActivity,
}

class _PickSendFilesResult {
  const _PickSendFilesResult({
    required this.requests,
    this.skippedFileNames = const <String>[],
    this.usedFallback = false,
  });

  final List<Map<String, String>> requests;
  final List<String> skippedFileNames;
  final bool usedFallback;
}

class ClipboardTransferScreen extends StatefulWidget {
  final String? deviceId;
  final String? displayName;
  final Future<List<Map<String, String>>> Function()? pickSendFilesOverride;
  final bool? revealCompletedTransfersInFolderOverride;
  final ValueNotifier<String?>? routeNotifier;
  final ValueNotifier<String?>? sharedClipboardTextNotifier;

  const ClipboardTransferScreen({
    super.key,
    this.deviceId,
    this.displayName,
    this.pickSendFilesOverride,
    this.revealCompletedTransfersInFolderOverride,
    this.routeNotifier,
    this.sharedClipboardTextNotifier,
  });

  @override
  State<ClipboardTransferScreen> createState() =>
      _ClipboardTransferScreenState();
}

class _ClipboardTransferScreenState extends State<ClipboardTransferScreen> {
  static const _legacyQueueCoordinator = LegacySendQueueCoordinator();
  final List<Map<String, dynamic>> _clipboardOffers = [];
  final List<Map<String, dynamic>> _incomingFileOffers = [];
  final List<Map<String, dynamic>> _fileTransfers = [];
  final List<Map<String, dynamic>> _trustedPeers = [];
  final Set<String> _hiddenOfferIds = <String>{};
  final Set<String> _legacySendingFilePeerIds = <String>{};

  StreamSubscription<Map<String, dynamic>>? _clipboardOfferSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardExpiredSub;
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileProgressSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<bool>? _connectionChangedSub;

  bool _isRefreshing = false;
  _HistorySection _activeSection = _HistorySection.clipboard;
  String? _localDeviceId;
  String? _localDisplayName;
  final Set<String> _clipboardFilteredSourceDeviceIds = <String>{};
  final Set<String> _clipboardFilteredTypes = <String>{};
  final Set<String> _selectedIncomingOffers = <String>{};
  final Set<String> _selectedSendDeviceIds = <String>{};
  bool _hasUserModifiedSendDevices = false;
  static const Duration _presenceRefreshInterval = Duration(seconds: 5);
  Timer? _presenceRefreshTimer;

  bool get _revealCompletedTransfersInFolder =>
      widget.revealCompletedTransfersInFolderOverride ??
      shouldRevealCompletedTransferDestination();
  SendQueueController get _sendQueue => context.read<SendQueueController>();
  SendQueueModeCoordinator get _queueMode =>
      SendQueueModeCoordinator(_sendQueue, _legacyQueueCoordinator);
  String get _screenTitle {
    if (widget.displayName != null && widget.displayName!.isNotEmpty) {
      return 'Activity — ${widget.displayName}';
    }
    return 'Activity';
  }

  String get _screenSubtitle {
    return 'Everything happening between you and your trusted devices.';
  }

  @override
  void initState() {
    super.initState();
    widget.routeNotifier?.addListener(_handleExternalRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleExternalRoute();
      _bindStreams();
      unawaited(_restoreStagedQueue());
      _refreshAll();
    });
  }

  @override
  void dispose() {
    widget.routeNotifier?.removeListener(_handleExternalRoute);
    _clipboardOfferSub?.cancel();
    _clipboardExpiredSub?.cancel();
    _fileOfferSub?.cancel();
    _fileProgressSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    _trustChangedSub?.cancel();
    _connectionChangedSub?.cancel();
    _presenceRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPresenceRefreshLoop();
    });
  }

  void _syncPresenceRefreshLoop() {
    final route = ModalRoute.of(context);
    final isRouteCurrent = route == null || route.isCurrent;
    final shouldRefresh = mounted && isRouteCurrent && _trustedPeers.isNotEmpty;
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
      final r = ModalRoute.of(context);
      final current = r == null || r.isCurrent;
      if (!current || !client.isConnected || _trustedPeers.isEmpty) {
        _syncPresenceRefreshLoop();
        return;
      }
      unawaited(_refreshTrustedPeers());
    });
  }

  void _handleExternalRoute() {
    final route = widget.routeNotifier?.value;
    if (route == null || !mounted) {
      return;
    }

    final nextSection = switch (route) {
      NotificationRoute.historyClipboard => _HistorySection.clipboard,
      NotificationRoute.historySend => _HistorySection.send,
      NotificationRoute.historyIncomingOffers => _HistorySection.incomingOffers,
      NotificationRoute.historyTransferActivity =>
        _HistorySection.transferActivity,
      _ => null,
    };
    if (nextSection != null) {
      setState(() => _activeSection = nextSection);
    }
    widget.routeNotifier?.value = null;
  }

  void _bindStreams() {
    final client = context.read<JsonRpcRiftClient>();
    _clipboardOfferSub = client.onClipboardOffer.listen((_) {
      if (mounted) {
        unawaited(_refreshClipboardOffers());
      }
    });
    _clipboardExpiredSub = client.onClipboardExpired.listen((_) {
      if (mounted) {
        unawaited(_refreshClipboardOffers());
      }
    });
    _fileOfferSub = client.onFileOffer.listen((_) {
      if (mounted) {
        unawaited(_refreshFileOffers());
        unawaited(_refreshTransfers());
      }
    });
    _fileProgressSub = client.onFileTransferProgress.listen((event) {
      unawaited(_handleLegacyTransferProgress(event));
      if (mounted) {
        unawaited(_refreshTransfers());
      }
    });
    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      unawaited(_handleLegacyTransferCompleted(event));
      if (mounted) {
        unawaited(_refreshFileOffers());
        unawaited(_refreshTransfers());
      }
    });
    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      unawaited(_handleLegacyTransferFailed(event));
      if (mounted) {
        unawaited(_refreshFileOffers());
        unawaited(_refreshTransfers());
      }
    });
    _trustChangedSub = client.onTrustChanged.listen((_) {
      if (mounted) {
        unawaited(_refreshTrustedPeers());
      }
    });
    _connectionChangedSub = client.onConnectionChanged.listen((isConnected) {
      if (!mounted || !isConnected) {
        return;
      }
      unawaited(_refreshTrustedPeers().then((_) => _resumeRecoverableQueue()));
    });
  }

  Future<void> _refreshAll() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await Future.wait<void>([
        _refreshLocalDeviceInfo(),
        _refreshTrustedPeers(),
      ]);
      await Future.wait<void>([
        _refreshClipboardOffers(),
        _refreshFileOffers(),
        _refreshTransfers(),
      ]);
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  Future<void> _refreshLocalDeviceInfo() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final info = await client.getDeviceInfo() as Map;
      if (!mounted) return;
      setState(() {
        _localDeviceId = info['deviceId']?.toString();
        _localDisplayName = info['displayName']?.toString();
      });
    } catch (_) {}
  }

  Future<void> _restoreStagedQueue() async {
    if (!mounted) {
      return;
    }
    await _sendQueue.restore();
    if (!mounted) {
      return;
    }
    setState(() {
      // Queue state lives in controller; rebuild after restore.
    });
    unawaited(_persistStagedQueue());
  }

  Future<void> _persistStagedQueue() => _sendQueue.persist();

  bool _matchesDeviceFilter(String? deviceId) {
    final filter = widget.deviceId;
    if (filter == null || filter.isEmpty) {
      return true;
    }
    return deviceId == filter;
  }

  Future<void> _refreshClipboardOffers() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listClipboardOffers();
      final offers = List<Map<String, dynamic>>.from(
        (result['offers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );

      final visibleOffers = offers.where((offer) {
        final offerId = offer['offerId']?.toString();
        final sourceDeviceId = offer['sourceDeviceId']?.toString();
        final isLocal =
            (_localDeviceId != null && sourceDeviceId == _localDeviceId) ||
                (widget.deviceId != null && sourceDeviceId == widget.deviceId);
        return !isLocal &&
            (offerId == null || !_hiddenOfferIds.contains(offerId)) &&
            _matchesDeviceFilter(sourceDeviceId);
      }).toList();

      visibleOffers.sort((a, b) {
        final aTime = DateTime.tryParse(a['expiresAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = DateTime.tryParse(b['expiresAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

      final dedupedOffers = <Map<String, dynamic>>[];
      final seenFingerprints = <String>{};
      for (final offer in visibleOffers) {
        final signature = [
          offer['sourceDeviceId']?.toString() ?? '',
          offer['sha256']?.toString() ?? '',
          offer['byteSize']?.toString() ?? '',
        ].join(':');
        if (seenFingerprints.add(signature)) {
          dedupedOffers.add(offer);
        }
      }

      if (!mounted) return;
      setState(() {
        _clipboardOffers
          ..clear()
          ..addAll(dedupedOffers.take(8));
      });
    } catch (_) {
      if (!mounted) return;
    }
  }

  Future<void> _refreshFileOffers() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listIncomingFileOffers();
      final offers = List<Map<String, dynamic>>.from(
        (result['offers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ).where((offer) {
        final sourceDeviceId = offer['sourceDeviceId']?.toString();
        return _matchesDeviceFilter(sourceDeviceId);
      }).toList(growable: false);

      if (!mounted) return;
      setState(() {
        _incomingFileOffers
          ..clear()
          ..addAll(offers);
      });
    } catch (_) {
      if (!mounted) return;
    }
  }

  Future<void> _refreshTransfers() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listFileTransfers();
      final transfers = List<Map<String, dynamic>>.from(
        (result['transfers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ).where((transfer) {
        final peerDeviceId = transfer['peerDeviceId']?.toString();
        return _matchesDeviceFilter(peerDeviceId);
      }).toList(growable: false);

      if (!mounted) return;
      setState(() {
        _fileTransfers
          ..clear()
          ..addAll(transfers);

        final activeTransferIds = transfers
            .map((t) => t['transferId']?.toString())
            .where((id) => id != null)
            .toSet();
        _incomingFileOffers.removeWhere((offer) =>
            activeTransferIds.contains(offer['transferId']?.toString()));
      });
    } catch (_) {
      if (!mounted) return;
    }
  }

  Future<void> _refreshTrustedPeers() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listTrustedPeers();
      final peers = List<Map<String, dynamic>>.from(
        (result['peers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ).where((peer) {
        final deviceId = peer['deviceId']?.toString();
        return _matchesDeviceFilter(deviceId);
      }).toList(growable: false);

      if (!mounted) return;
      setState(() {
        _trustedPeers
          ..clear()
          ..addAll(peers);
      });
      unawaited(_reconcileLegacyStagedQueueWithTrustedPeers());
      unawaited(_resumeRecoverableQueue());
    } catch (_) {
      if (!mounted) return;
    } finally {
      _syncPresenceRefreshLoop();
    }
  }

  String _peerDisplayName(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return 'Unknown device';
    }
    if (deviceId == _localDeviceId) {
      return _localDisplayName != null && _localDisplayName!.isNotEmpty
          ? '$_localDisplayName (This Device)'
          : 'This Device';
    }
    for (final peer in _trustedPeers) {
      if (peer['deviceId']?.toString() == deviceId) {
        final displayName = peer['displayName']?.toString().trim();
        if (displayName != null && displayName.isNotEmpty) {
          return displayName;
        }
      }
    }
    if (widget.deviceId == deviceId &&
        widget.displayName != null &&
        widget.displayName!.trim().isNotEmpty) {
      return widget.displayName!.trim();
    }
    if (deviceId.length <= 16) {
      return deviceId;
    }
    return '${deviceId.substring(0, 12)}...';
  }

  String _peerMenuLabel(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return 'Unknown device';
    }
    final peer = _trustedPeers.cast<Map<String, dynamic>?>().firstWhere(
          (entry) => entry?['deviceId']?.toString() == deviceId,
          orElse: () => null,
        );
    final displayName = _peerDisplayName(deviceId);
    if (peer != null) {
      final rawPlatform = peer['platform']?.toString().trim();
      if (rawPlatform != null &&
          rawPlatform.isNotEmpty &&
          rawPlatform.toLowerCase() != 'unknown') {
        final platformFormatted = _formatPlatformName(rawPlatform);
        if (!displayName.toLowerCase().contains(rawPlatform.toLowerCase())) {
          return '$displayName · $platformFormatted';
        }
      }
    }
    return displayName;
  }

  String _formatPlatformName(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      case 'macos':
        return 'macOS';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      default:
        if (platform.isEmpty) return '';
        return platform[0].toUpperCase() + platform.substring(1);
    }
  }

  void _reconcileStagedQueueWithTrustedPeers() {
    if (!mounted) {
      return;
    }

    final fileCapablePeerIds = _fileCapablePeers
        .map((peer) => peer['deviceId']?.toString() ?? '')
        .where((deviceId) => deviceId.isNotEmpty)
        .toSet();

    var changed = false;
    for (final staged in _sendQueue.items) {
      if (staged.status == SendQueueStatus.sent) {
        continue;
      }
      final targetDeviceId = staged.targetDeviceId;
      if (targetDeviceId == null || targetDeviceId.isEmpty) {
        continue;
      }
      if (fileCapablePeerIds.contains(targetDeviceId)) {
        continue;
      }

      final nextMessage =
          'Target device ${_peerDisplayName(targetDeviceId)} is no longer available for file transfer.';
      if (staged.status != SendQueueStatus.failed ||
          staged.errorMessage != nextMessage ||
          staged.autoRetryWhenPeerAvailable ||
          staged.transferId != null ||
          staged.operationId != null ||
          staged.bytesTransferred != 0) {
        staged.status = SendQueueStatus.failed;
        staged.errorMessage = nextMessage;
        staged.autoRetryWhenPeerAvailable = false;
        staged.transferId = null;
        staged.operationId = null;
        staged.bytesTransferred = 0;
        changed = true;
      }
    }

    if (changed) {
      setState(() {});
      unawaited(_persistStagedQueue());
    }
  }

  Future<void> _reconcileLegacyStagedQueueWithTrustedPeers() async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    _reconcileStagedQueueWithTrustedPeers();
  }

  Future<void> _handleLegacyTransferProgress(Map<String, dynamic> event) async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    _applyTransferProgress(event);
  }

  Future<void> _handleLegacyTransferCompleted(
      Map<String, dynamic> event) async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    _applyTransferCompleted(event);
  }

  Future<void> _handleLegacyTransferFailed(Map<String, dynamic> event) async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    _applyTransferFailed(event);
  }

  void _applyTransferProgress(Map<String, dynamic> event) {
    final transferId = event['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) {
      return;
    }

    final staged = _findStagedFileByTransferId(transferId);
    if (staged == null || !mounted) {
      return;
    }

    setState(() {
      staged.bytesTransferred = (event['bytesTransferred'] as num?)?.toInt() ??
          staged.bytesTransferred;
      staged.status = SendQueueStatus.sending;
    });
    unawaited(_persistStagedQueue());
  }

  void _applyTransferCompleted(Map<String, dynamic> event) {
    final transferId = event['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) {
      return;
    }

    final staged = _findStagedFileByTransferId(transferId);
    if (staged == null || !mounted) {
      return;
    }

    setState(() {
      staged.bytesTransferred = staged.byteSize;
      staged.status = SendQueueStatus.sent;
      staged.errorMessage = null;
      staged.autoRetryWhenPeerAvailable = false;
    });
    unawaited(_persistStagedQueue());
  }

  void _applyTransferFailed(Map<String, dynamic> event) {
    final transferId = event['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) {
      return;
    }

    final staged = _findStagedFileByTransferId(transferId);
    if (staged == null || !mounted) {
      return;
    }

    final rawMessage =
        event['message']?.toString() ?? event['failureReason']?.toString();
    final shouldAutoRecover = _isRecoverableTransferFailure(event, rawMessage);

    setState(() {
      staged.status =
          shouldAutoRecover ? SendQueueStatus.queued : SendQueueStatus.failed;
      staged.errorMessage = shouldAutoRecover
          ? 'Connection lost. Waiting to retry when ${_peerDisplayName(staged.targetDeviceId)} is available again.'
          : rawMessage;
      staged.autoRetryWhenPeerAvailable = shouldAutoRecover;
      if (shouldAutoRecover) {
        staged.transferId = null;
        staged.operationId = null;
        staged.bytesTransferred = 0;
      }
    });
    unawaited(_persistStagedQueue());
  }

  bool _isRecoverableTransferFailure(
    Map<String, dynamic> event,
    String? rawMessage,
  ) {
    final failureReason = event['failureReason']?.toString().toLowerCase();
    final haystack = [
      rawMessage?.toLowerCase() ?? '',
      failureReason ?? '',
    ].join(' ');

    const terminalHints = <String>[
      'peerrejected',
      'capabilityunavailable',
      'hashmismatch',
      'policiedenied',
      'unauthorized',
      'invalidtransition',
      'invalid request',
      'notfound',
      'permission denied',
      'access denied',
      'no such file',
      'does not exist',
      'missing file',
    ];
    for (final hint in terminalHints) {
      if (haystack.contains(hint)) {
        return false;
      }
    }

    const recoverableHints = <String>[
      'peerunreachable',
      'timeout',
      'timed out',
      'no active session',
      'reconnect',
      'unreachable',
      'connection lost',
      'connection reset',
      'broken pipe',
      'socket',
      'session closed',
      'session expired',
      'transport closed',
      'offline',
    ];
    for (final hint in recoverableHints) {
      if (haystack.contains(hint)) {
        return true;
      }
    }

    return false;
  }

  Future<void> _resumeRecoverableQueue() async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    if (!mounted || _legacySendingFilePeerIds.isNotEmpty) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();

    final recoverableFiles = _sendQueue.items.where((file) {
      return file.status == SendQueueStatus.queued &&
          file.autoRetryWhenPeerAvailable &&
          file.targetDeviceId != null &&
          file.targetDeviceId!.isNotEmpty;
    }).toList(growable: false);

    if (recoverableFiles.isEmpty) {
      return;
    }

    if (!client.isConnected) {
      return;
    }

    final resumableByPeer = await _queueMode.groupRecoverableLegacyFilesByPeer(
      files: recoverableFiles,
      isPeerOnline: (deviceId) {
        final peer = _fileCapablePeers.cast<Map<String, dynamic>?>().firstWhere(
              (candidate) => candidate?['deviceId']?.toString() == deviceId,
              orElse: () => null,
            );
        return peer != null && peer['presence']?.toString() == 'online';
      },
    );

    for (final entry in resumableByPeer.entries) {
      final deviceId = entry.key;
      if (_legacySendingFilePeerIds.contains(deviceId)) {
        continue;
      }
      if (!mounted) return;
      setState(() => _legacySendingFilePeerIds.add(deviceId));
      try {
        await _resumeLegacyRecoverableQueue(client: client, deviceId: deviceId);
      } finally {
        if (mounted) {
          setState(() => _legacySendingFilePeerIds.remove(deviceId));
        }
      }
    }
  }

  Future<int> _resumeLegacyRecoverableQueue({
    required JsonRpcRiftClient client,
    required String deviceId,
    List<SendQueueEntry>? files,
  }) async {
    final filesToSubmit = files ??
        _sendQueue.eligibleForPeer(deviceId).where((file) {
          return file.autoRetryWhenPeerAvailable;
        }).toList(growable: false);
    return _legacyQueueCoordinator.submitFilesToPeer(
      client: client,
      deviceId: deviceId,
      files: filesToSubmit,
      isMounted: () => mounted,
      mutateUi: (mutation) {
        if (!mounted) {
          return;
        }
        setState(mutation);
      },
      persistQueue: _persistStagedQueue,
      onSubmitted: (staged) {
        if (!mounted) {
          return;
        }
        setState(() {
          staged.autoRetryWhenPeerAvailable = false;
          _activeSection = _HistorySection.transferActivity;
        });
      },
    );
  }

  SendQueueEntry? _findStagedFileByTransferId(String transferId) {
    for (final staged in _sendQueue.items) {
      if (staged.transferId == transferId) {
        return staged;
      }
    }
    return null;
  }

  String _transferPeerSummary(Map<String, dynamic> transfer) {
    final peerLabel = _peerDisplayName(transfer['peerDeviceId']?.toString());
    switch (transfer['direction']?.toString()) {
      case 'incoming':
        return 'Received from $peerLabel';
      case 'outgoing':
        return 'Sending to $peerLabel';
      default:
        return 'Peer: $peerLabel';
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

  List<Map<String, dynamic>> get _fileCapablePeers {
    return _trustedPeers.where((peer) {
      final trustState = peer['trustState']?.toString();
      if (trustState != 'trusted') return false;

      final capabilitiesList = peer['capabilities'] as List?;
      if (capabilitiesList == null || capabilitiesList.isEmpty) {
        return true;
      }

      final capabilities = List<String>.from(
        capabilitiesList.map((item) => item.toString()),
      );
      return capabilities.contains('file.transfer');
    }).toList(growable: false);
  }

  List<Map<String, dynamic>> get _activeOutgoingTransfers {
    return _fileTransfers.where((transfer) {
      final direction = transfer['direction']?.toString();
      final state = transfer['state']?.toString().toLowerCase();
      return direction == 'outgoing' &&
          state != 'done' &&
          state != 'failed' &&
          state != 'cancelled';
    }).toList(growable: false);
  }

  Future<Map<String, String>?> _showSendFileFallbackDialog() async {
    final pathController = TextEditingController();
    final nameController = TextEditingController();
    final typeController =
        TextEditingController(text: 'application/octet-stream');
    String? validationError;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final path = pathController.text.trim();
              final name = nameController.text.trim();
              final type = typeController.text.trim();
              if (path.isEmpty) {
                setDialogState(() {
                  validationError = 'Enter a local file path.';
                });
                return;
              }
              if (!File(path).existsSync()) {
                setDialogState(() {
                  validationError = 'That file path does not exist.';
                });
                return;
              }
              Navigator.of(dialogContext).pop({
                'localPath': path,
                'fileName': name,
                'mediaType': type,
              });
            }

            return PremiumDialog(
              title: 'Send File',
              subtitle:
                  'Could not open the native file picker. Please specify the file details manually.',
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PremiumTextField(
                    controller: pathController,
                    label: 'Local path',
                    hint: '/home/you/Downloads/example.mp4',
                    autofocus: true,
                  ),
                  const SizedBox(height: 12),
                  PremiumTextField(
                    controller: nameController,
                    label: 'Display file name (optional)',
                  ),
                  const SizedBox(height: 12),
                  PremiumTextField(
                    controller: typeController,
                    label: 'Media type',
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
              cancelText: 'Cancel',
              confirmText: 'Send',
              onCancel: () => Navigator.of(dialogContext).pop(),
              onConfirm: submit,
            );
          },
        );
      },
    );

    return result;
  }

  Future<_PickSendFilesResult> _pickSendFileRequests() async {
    if (widget.pickSendFilesOverride != null) {
      return _PickSendFilesResult(
        requests: await widget.pickSendFilesOverride!.call(),
      );
    }
    try {
      if (Platform.isMacOS) {
        final requests = await MacOSSendFiles.pickSendFiles();
        return _PickSendFilesResult(requests: requests);
      }
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        withReadStream: true,
        lockParentWindow: true,
      );
      final pickedFiles = result?.files ?? const <PlatformFile>[];
      if (pickedFiles.isEmpty) {
        return const _PickSendFilesResult(requests: <Map<String, String>>[]);
      }

      final requests = <Map<String, String>>[];
      final skippedFileNames = <String>[];
      for (final picked in pickedFiles) {
        final resolvedPath = await _materializePickedFile(picked);
        if (resolvedPath == null || resolvedPath.isEmpty) {
          skippedFileNames.add(
            picked.name.trim().isEmpty ? 'Unnamed file' : picked.name,
          );
          continue;
        }
        requests.add({
          'localPath': resolvedPath,
          'fileName': picked.name,
          'mediaType': _guessMediaTypeFromName(picked.name),
        });
      }
      return _PickSendFilesResult(
        requests: requests,
        skippedFileNames: skippedFileNames,
      );
    } catch (_) {
      final fallback = await _showSendFileFallbackDialog();
      if (fallback == null) {
        return const _PickSendFilesResult(requests: <Map<String, String>>[]);
      }
      return _PickSendFilesResult(
        requests: <Map<String, String>>[fallback],
        usedFallback: true,
      );
    }
  }

  Future<String?> _materializePickedFile(PlatformFile picked) async {
    final directPath = picked.path;
    if (directPath != null &&
        directPath.isNotEmpty &&
        await File(directPath).exists()) {
      return directPath;
    }

    final tempRoot = await getTemporaryDirectory();
    final stagingDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}rift-send-staging',
    );
    await stagingDir.create(recursive: true);

    final safeName = picked.name.trim().isEmpty
        ? 'attachment.bin'
        : picked.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final stagedPath =
        '${stagingDir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}_$safeName';
    final stagedFile = File(stagedPath);

    if (picked.readStream != null) {
      final sink = stagedFile.openWrite();
      try {
        await for (final chunk in picked.readStream!) {
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (await stagedFile.exists()) {
        return stagedPath;
      }
    }

    final bytes = picked.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      await stagedFile.writeAsBytes(bytes, flush: true);
      return stagedPath;
    }

    return null;
  }

  Future<void> _addFilesToSendQueue() async {
    final messenger = ScaffoldMessenger.of(context);
    final pickResult = await _pickSendFileRequests();
    final requests = pickResult.requests;
    if (!mounted) {
      return;
    }
    if (requests.isEmpty) {
      if (pickResult.skippedFileNames.isNotEmpty) {
        RiftSnackbar.showWithState(
          messenger: messenger,
          message:
              'Could not read ${pickResult.skippedFileNames.length} selected file(s).',
          type: RiftSnackbarType.error,
        );
      }
      return;
    }
    await _queueSendRequests(
      requests,
      skippedUnreadableCount: pickResult.skippedFileNames.length,
      successPrefix: 'Added',
    );
  }

  Future<void> _queueSendRequests(
    List<Map<String, String>> requests, {
    int skippedUnreadableCount = 0,
    bool switchToSendSection = false,
    required String successPrefix,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await _sendQueue.enqueueRequests(requests);
    if (!mounted) {
      return;
    }

    if (result.isEmpty) {
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: 'No new file was added to the send queue.',
        type: RiftSnackbarType.warning,
      );
      return;
    }

    setState(() {
      if (switchToSendSection) {
        _activeSection = _HistorySection.send;
      }
    });
    RiftSnackbar.showWithState(
      messenger: messenger,
      message: [
        '$successPrefix ${result.added} file(s) in the send queue.',
        if (result.skipped > 0)
          'Skipped ${result.skipped} duplicate/unavailable item(s).',
        if (skippedUnreadableCount > 0)
          'Could not read $skippedUnreadableCount selected file(s).',
      ].join(' '),
      type: RiftSnackbarType.info,
    );
  }

  void _toggleSendDevice(String deviceId, Set<String> effectiveSelectedIds) {
    setState(() {
      if (!_hasUserModifiedSendDevices) {
        _hasUserModifiedSendDevices = true;
        _selectedSendDeviceIds.clear();
        _selectedSendDeviceIds.addAll(effectiveSelectedIds);
      }
      if (_selectedSendDeviceIds.contains(deviceId)) {
        _selectedSendDeviceIds.remove(deviceId);
      } else {
        _selectedSendDeviceIds.add(deviceId);
      }
    });
  }

  Future<void> _sendStagedFilesToSelectedPeers() async {
    final peers = _fileCapablePeers;
    if (peers.isEmpty) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'No trusted peer currently advertises file.transfer capability.',
        type: RiftSnackbarType.warning,
      );
      return;
    }
    final effectiveSelectedIds = _selectedSendDeviceIds.isNotEmpty || _hasUserModifiedSendDevices
        ? _selectedSendDeviceIds.intersection(peers.map((p) => p['deviceId']?.toString() ?? '').toSet())
        : <String>{peers.first['deviceId']?.toString() ?? ''};
    if (effectiveSelectedIds.isEmpty) return;
    for (final deviceId in effectiveSelectedIds) {
      final peer = peers.firstWhere(
        (p) => p['deviceId']?.toString() == deviceId,
        orElse: () => <String, dynamic>{},
      );
      if (peer.isNotEmpty) {
        await _sendStagedFilesToPeer(peer);
      }
    }
  }

  Future<void> _sendStagedFilesToPeer(Map<String, dynamic> peer) async {
    final deviceId = peer['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;
    final isLegacyMode = await _queueMode.isLegacyLocalQueueMode();
    if (!mounted) {
      return;
    }
    final client = context.read<JsonRpcRiftClient>();
    final queuedFiles = _eligibleFilesForPeer(deviceId);
    if (queuedFiles.isEmpty) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message:
            'No queued file is ready to send to ${_peerDisplayName(deviceId)}.',
        type: RiftSnackbarType.warning,
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    if (isLegacyMode) {
      setState(() => _legacySendingFilePeerIds.add(deviceId));
    }

    try {
      final submitted = await _queueMode.dispatchToPeer(
        client: client,
        deviceId: deviceId,
        isMounted: () => mounted,
        mutateUi: (mutation) {
          if (!mounted) {
            return;
          }
          setState(mutation);
        },
        persistQueue: _persistStagedQueue,
        onLegacySubmitted: (staged) {
          if (!mounted) {
            return;
          }
          setState(() {
            staged.autoRetryWhenPeerAvailable = false;
            _activeSection = _HistorySection.transferActivity;
          });
        },
      );
      if (!mounted) return;
      if (submitted > 0) {
        setState(() => _activeSection = _HistorySection.transferActivity);
      } else {
        RiftSnackbar.showWithState(
          messenger: messenger,
          message: 'No file was submitted to ${_peerDisplayName(deviceId)}.',
          type: RiftSnackbarType.warning,
        );
      }
      await _refreshTransfers();
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: JsonRpcRiftClient.formatDisplayError(e),
        type: RiftSnackbarType.error,
      );
    } finally {
      if (mounted && isLegacyMode) {
        setState(() => _legacySendingFilePeerIds.remove(deviceId));
      }
    }
  }

  // ignore: unused_element
  bool _hasActiveOutgoingTransferForPeer(String deviceId) {
    return _activeOutgoingTransfers.any(
      (transfer) => transfer['peerDeviceId']?.toString() == deviceId,
    );
  }

  List<SendQueueEntry> _eligibleFilesForPeer(String deviceId) {
    return _sendQueue.items.where((file) {
      return SendQueueTargeting.isEligibleForPeer(
        status: file.status,
        targetDeviceId: file.targetDeviceId,
        peerDeviceId: deviceId,
      );
    }).toList(growable: false);
  }

  // ignore: unused_element
  SendQueuePeerSummary _peerQueueSummary(String deviceId) {
    return SendQueueSummary.forPeer(
      peerDeviceId: deviceId,
      items: _sendQueue.items
          .map(
            (file) => SendQueueSummaryEntry(
              status: file.status,
              targetDeviceId: file.targetDeviceId,
              isWaitingForReconnect: file.autoRetryWhenPeerAvailable,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<void> _cancelStagedFile(SendQueueEntry file) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _sendQueue.cancelItem(file);
      if (!mounted) {
        return;
      }
      setState(() {});
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: file.status == SendQueueStatus.sending
            ? 'Cancelled ${file.fileName}.'
            : 'Removed ${file.fileName} from the queue.',
        type: RiftSnackbarType.info,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: JsonRpcRiftClient.formatDisplayError(error),
        type: RiftSnackbarType.error,
      );
    }
  }

  // ignore: unused_element
  Future<void> _clearFinishedStagedFiles() async {
    final sentItems = _sendQueue.items
        .where((file) => file.status == SendQueueStatus.sent)
        .toList(growable: false);
    for (final item in sentItems) {
      await _sendQueue.removeItem(item);
    }
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _retryFailedStagedFile(SendQueueEntry file) async {
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<JsonRpcRiftClient>();
    final deviceId = file.targetDeviceId;
    var handledByCallback = false;
    final peerExists = deviceId != null &&
        deviceId.isNotEmpty &&
        _fileCapablePeers.any(
          (candidate) => candidate['deviceId']?.toString() == deviceId,
        );

    final success = await _queueMode.retryFailedItem(
      client: client,
      file: file,
      peerExists: peerExists,
      isMounted: () => mounted,
      mutateUi: (mutation) {
        if (!mounted) {
          return;
        }
        setState(mutation);
      },
      persistQueue: _persistStagedQueue,
      onNeedsPeerSelection: () {
        if (!mounted) {
          return;
        }
        setState(() {
          _activeSection = _HistorySection.send;
        });
        RiftSnackbar.showWithState(
          messenger: messenger,
          message: 'File moved back to queue. Choose a peer to send it again.',
          type: RiftSnackbarType.info,
        );
      },
      onPeerUnavailable: (peerDeviceId) {
        handledByCallback = true;
        if (!mounted) {
          return;
        }
        setState(() {
          file.status = SendQueueStatus.failed;
          file.errorMessage =
              'Target device ${_peerDisplayName(peerDeviceId)} is no longer available for file transfer.';
          file.autoRetryWhenPeerAvailable = false;
          file.transferId = null;
          file.operationId = null;
          file.bytesTransferred = 0;
        });
        unawaited(_persistStagedQueue());
        RiftSnackbar.showWithState(
          messenger: messenger,
          message:
              '${_peerDisplayName(peerDeviceId)} is no longer available for file transfer.',
          type: RiftSnackbarType.error,
        );
      },
      onLegacySubmitted: (staged) {
        if (!mounted) {
          return;
        }
        setState(() {
          staged.autoRetryWhenPeerAvailable = false;
          _activeSection = _HistorySection.transferActivity;
        });
      },
    );
    if (!mounted || handledByCallback || deviceId == null || deviceId.isEmpty) {
      return;
    }
    RiftSnackbar.showWithState(
      messenger: messenger,
      message: success
          ? 'Retry queued for ${file.fileName}.'
          : 'Retry failed for ${file.fileName}.',
      type: success ? RiftSnackbarType.success : RiftSnackbarType.error,
    );
  }

  bool _hasUnavailableTarget(SendQueueEntry file) {
    final message = file.errorMessage?.toLowerCase() ?? '';
    return file.status == SendQueueStatus.failed &&
        message.contains('no longer available for file transfer');
  }

  void _chooseDeviceForStagedFile(SendQueueEntry file) {
    unawaited(() async {
      await _sendQueue.retargetForSelection(file);
      if (!mounted) {
        return;
      }
      setState(() {});
      RiftSnackbar.show(
        context: context,
        message: 'Choose a device below to send ${file.fileName} again.',
        type: RiftSnackbarType.info,
      );
    }());
  }

  Future<void> _openTransferDestination(
    String destinationPath, {
    required bool revealInFolder,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (revealInFolder) {
        await showFileInFolder(destinationPath);
      } else {
        await openFilePath(destinationPath);
      }
    } catch (error) {
      if (!mounted) return;
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: 'Could not open saved file: $error',
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<String?> _defaultDestinationPath(String suggestedFileName) async {
    return buildDefaultIncomingFilePath(suggestedFileName);
  }

  Future<String?> _showDestinationFallbackDialog(
      String suggestedFileName) async {
    final resolvedDefaultPath =
        await _defaultDestinationPath(suggestedFileName);
    if (!mounted) return null;

    final destinationController = TextEditingController(
      text: resolvedDefaultPath ??
          (Platform.isWindows
              ? r'C:\Users\Public\Downloads\' + suggestedFileName
              : '/tmp/$suggestedFileName'),
    );
    String? validationError;

    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final path = destinationController.text.trim();
              if (path.isEmpty) {
                setDialogState(() {
                  validationError = 'Enter a destination path.';
                });
                return;
              }
              Navigator.of(dialogContext).pop(path);
            }

            return PremiumDialog(
              title: 'Save Incoming File',
              subtitle:
                  'Could not open the native file picker. Please specify the destination path manually.',
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PremiumTextField(
                    controller: destinationController,
                    label: 'Destination path',
                    autofocus: true,
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
              cancelText: 'Cancel',
              confirmText: 'Accept',
              onCancel: () => Navigator.of(dialogContext).pop(),
              onConfirm: submit,
            );
          },
        );
      },
    );
  }

  Future<String?> _pickDestinationPath(String suggestedFileName) async {
    try {
      final defaultPath = await _defaultDestinationPath(suggestedFileName);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save incoming file',
        fileName: suggestedFileName,
        initialDirectory:
            defaultPath == null ? null : File(defaultPath).parent.path,
        lockParentWindow: true,
      );
      if (path == null || path.isEmpty) {
        return null;
      }
      return path;
    } catch (_) {
      return _showDestinationFallbackDialog(suggestedFileName);
    }
  }

  Future<void> _acceptIncomingOffer(Map<String, dynamic> offer) async {
    final transferId = offer['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) return;

    final destinationPath = await _pickDestinationPath(
      offer['fileName']?.toString() ?? 'incoming.bin',
    );
    if (destinationPath == null || destinationPath.isEmpty || !mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<JsonRpcRiftClient>().acceptFileOffer(
            transferId: transferId,
            destinationPath: destinationPath,
          );
      if (!mounted) return;
      setState(() {
        _activeSection = _HistorySection.transferActivity;
      });
      await _refreshFileOffers();
      await _refreshTransfers();
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: JsonRpcRiftClient.formatDisplayError(e),
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _rejectIncomingOffer(Map<String, dynamic> offer) async {
    final transferId = offer['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<JsonRpcRiftClient>().rejectFileOffer(
            transferId: transferId,
            failureReason: 'PolicyDenied',
            message: 'User declined from history screen',
          );
      if (!mounted) return;
      await _refreshFileOffers();
      await _refreshTransfers();
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: JsonRpcRiftClient.formatDisplayError(e),
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _rejectSelectedOffers() async {
    final toReject = _selectedIncomingOffers.toList();
    setState(() => _selectedIncomingOffers.clear());
    for (final id in toReject) {
      final offer = _incomingFileOffers.firstWhere(
        (o) => o['transferId']?.toString() == id,
        orElse: () => <String, dynamic>{},
      );
      if (offer.isNotEmpty) {
        await _rejectIncomingOffer(offer);
      }
    }
  }

  Future<void> _saveSelectedOffers() async {
    final toSave = _selectedIncomingOffers.toList();
    setState(() => _selectedIncomingOffers.clear());
    for (final id in toSave) {
      final offer = _incomingFileOffers.firstWhere(
        (o) => o['transferId']?.toString() == id,
        orElse: () => <String, dynamic>{},
      );
      if (offer.isNotEmpty) {
        await _acceptIncomingOffer(offer);
      }
    }
  }

  String _guessMediaTypeFromName(String fileName) {
    final normalized = fileName.toLowerCase();
    if (normalized.endsWith('.txt')) return 'text/plain';
    if (normalized.endsWith('.json')) return 'application/json';
    if (normalized.endsWith('.pdf')) return 'application/pdf';
    if (normalized.endsWith('.csv')) return 'text/csv';
    if (normalized.endsWith('.md')) return 'text/markdown';
    if (normalized.endsWith('.jpg') || normalized.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (normalized.endsWith('.png')) return 'image/png';
    if (normalized.endsWith('.gif')) return 'image/gif';
    if (normalized.endsWith('.webp')) return 'image/webp';
    if (normalized.endsWith('.heic')) return 'image/heic';
    if (normalized.endsWith('.mp4')) return 'video/mp4';
    if (normalized.endsWith('.webm')) return 'video/webm';
    if (normalized.endsWith('.mov')) return 'video/quicktime';
    if (normalized.endsWith('.mkv')) return 'video/x-matroska';
    if (normalized.endsWith('.avi')) return 'video/x-msvideo';
    if (normalized.endsWith('.mp3')) return 'audio/mpeg';
    if (normalized.endsWith('.wav')) return 'audio/wav';
    if (normalized.endsWith('.zip')) return 'application/zip';
    if (normalized.endsWith('.7z')) return 'application/x-7z-compressed';
    if (normalized.endsWith('.tar')) return 'application/x-tar';
    if (normalized.endsWith('.gz')) return 'application/gzip';
    return 'application/octet-stream';
  }

  String _formatSize(num rawBytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = rawBytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final formatted = value >= 10 || unitIndex == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$formatted ${units[unitIndex]}';
  }

  IconData _mediaTypeIcon(String? mediaType) {
    final normalized = mediaType?.toLowerCase() ?? '';
    if (normalized.startsWith('video/')) return Icons.movie;
    if (normalized.startsWith('image/')) return Icons.image;
    if (normalized.startsWith('audio/')) return Icons.audiotrack;
    if (normalized == 'application/pdf') return Icons.picture_as_pdf;
    if (normalized.contains('zip') ||
        normalized.contains('tar') ||
        normalized.contains('7z') ||
        normalized.contains('gzip')) {
      return Icons.archive;
    }
    if (normalized.startsWith('text/')) return Icons.description;
    return Icons.insert_drive_file;
  }

  String _transferStateLabel(String state) {
    switch (state.toLowerCase()) {
      case 'done':
        return 'DONE';
      case 'failed':
        return 'FAILED';
      case 'active':
        return 'ACTIVE';
      case 'dispatched':
        return 'WAITING';
      case 'pending':
        return 'PENDING';
      default:
        return state.toUpperCase();
    }
  }

  Color _transferStateColor(ThemeData theme, String state) {
    switch (state.toLowerCase()) {
      case 'done':
        return theme.colorScheme.secondary;
      case 'failed':
        return theme.colorScheme.error;
      case 'active':
        return theme.colorScheme.primary;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SendQueueController>();
    final theme = Theme.of(context);
    final showScreenHeader = true;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: _activeSection == _HistorySection.incomingOffers &&
              _selectedIncomingOffers.isNotEmpty
          ? PreferredSize(
              preferredSize: const Size.fromHeight(64),
              child: _buildBulkSelectionBar(theme),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 100),
          children: [
            if (showScreenHeader) ...[
              Text(
                _screenTitle,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _screenSubtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
            ],
            if (_isRefreshing)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            _buildSectionTabBar(theme),
            const SizedBox(height: 16),
            _buildActiveSection(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTabBar(ThemeData theme) {
    final totalTransferCount = _fileTransfers.length;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildSectionChip(theme, _HistorySection.clipboard, 'Clipboard'),
            const SizedBox(width: 24),
            _buildSectionChip(theme, _HistorySection.send, 'Send File'),
            const SizedBox(width: 24),
            _buildSectionChip(
              theme,
              _HistorySection.incomingOffers,
              'Incoming Offers',
              badgeCount: _incomingFileOffers.isNotEmpty
                  ? _incomingFileOffers.length
                  : null,
            ),
            const SizedBox(width: 24),
            _buildSectionChip(
              theme,
              _HistorySection.transferActivity,
              'Transfer Activity',
              badgeCount: totalTransferCount > 0 ? totalTransferCount : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBulkSelectionBar(ThemeData theme) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.close,
                    color: theme.colorScheme.onPrimaryContainer),
                onPressed: () {
                  setState(() => _selectedIncomingOffers.clear());
                },
                tooltip: 'Cancel Selection',
              ),
              const SizedBox(width: 8),
              Text(
                '${_selectedIncomingOffers.length} items selected',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Row(
            children: [
              OutlinedButton(
                onPressed: _rejectSelectedOffers,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: theme.colorScheme.onPrimaryContainer),
                  foregroundColor: theme.colorScheme.onPrimaryContainer,
                ),
                child: const Text('Reject All'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saveSelectedOffers,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.onPrimaryContainer,
                  foregroundColor: theme.colorScheme.primaryContainer,
                ),
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Save All'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionChip(
    ThemeData theme,
    _HistorySection section,
    String label, {
    int? badgeCount,
  }) {
    final isSelected = _activeSection == section;
    final primaryColor = theme.colorScheme.primary;
    final onSurfaceVariant = theme.colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _activeSection = section;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? primaryColor : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? primaryColor : onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              if (badgeCount != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  constraints: const BoxConstraints(minWidth: 18),
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    badgeCount.toString(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: theme.colorScheme.onPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveSection(ThemeData theme) {
    switch (_activeSection) {
      case _HistorySection.clipboard:
        return _buildClipboardHistorySection(theme);
      case _HistorySection.send:
        return _buildFileSendSection(theme);
      case _HistorySection.incomingOffers:
        return _buildIncomingFileOffersSection(theme);
      case _HistorySection.transferActivity:
        return _buildTransferActivitySection(theme);
    }
  }

  Widget _buildClipboardHistorySection(ThemeData theme) {
    final visibleOffers = _visibleClipboardOffers;
    final totalSources = _clipboardSourceEntries.length;
    final totalTypes = _clipboardTypeEntries.length;

    final totalBytes = visibleOffers.fold<num>(
      0,
      (sum, o) => sum + (o['byteSize'] as num? ?? 0),
    );

    final autoSyncBanner = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF12744F).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 18, color: Color(0xFF12744F)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Sync is fully automatic — items below were copied to your clipboard the moment they arrived',
              style: theme.textTheme.labelMedium?.copyWith(
                color: const Color(0xFF12744F),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    final toolbar = Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildDeviceFilterMenu(theme, totalSources),
                _buildTypeFilterMenu(theme, totalTypes),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${visibleOffers.length}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                      Text(
                        'ITEMS',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatSize(totalBytes),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                      Text(
                        'TOTAL SIZE',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w600,
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
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        autoSyncBanner,
        toolbar,
        if (visibleOffers.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 48),
            alignment: Alignment.center,
            child: Text(
              _clipboardOffers.isEmpty
                  ? 'No recent clipboard items from connected devices yet.'
                  : 'No clipboard items match the current filters.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: visibleOffers.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) =>
                _buildClipboardOfferCard(theme, visibleOffers[index]),
          ),
      ],
    );
  }

  Widget _buildDeviceFilterMenu(ThemeData theme, int totalSources) {
    final activeCount = _clipboardFilteredSourceDeviceIds.isEmpty
        ? 0
        : _clipboardFilteredSourceDeviceIds
            .where((id) => id != '__none__')
            .length;
    final label = _clipboardFilteredSourceDeviceIds.isEmpty
        ? 'All devices'
        : '$activeCount of $totalSources';

    return MenuAnchor(
      style: MenuStyle(
        minimumSize: const WidgetStatePropertyAll(Size(280, 0)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        elevation: const WidgetStatePropertyAll(8),
        backgroundColor: const WidgetStatePropertyAll(
          Colors.white,
        ),
      ),
      builder: (context, controller, child) {
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            backgroundColor: Colors.white,
            side: BorderSide(
              color: controller.isOpen
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.devices,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (activeCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$activeCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(
                controller.isOpen
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        );
      },
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'SOURCE DEVICE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        if (_clipboardSourceEntries.isEmpty)
          MenuItemButton(
            onPressed: null,
            style: MenuItemButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              minimumSize: const Size(260, 48),
            ),
            child: const Text('No connected devices yet'),
          )
        else
          ..._clipboardSourceEntries.map((entry) {
            final deviceId = entry.key;
            final isSelected = _clipboardFilteredSourceDeviceIds.isEmpty ||
                (deviceId != null &&
                    _clipboardFilteredSourceDeviceIds.contains(deviceId));

            return MenuItemButton(
              style: MenuItemButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                minimumSize: const Size(260, 44),
              ),
              closeOnActivate: false,
              onPressed: () => _toggleDeviceFilter(deviceId),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleDeviceFilter(deviceId),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _peerMenuLabel(deviceId),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _buildTypeFilterMenu(ThemeData theme, int totalTypes) {
    final activeCount = _clipboardFilteredTypes.isEmpty
        ? 0
        : _clipboardFilteredTypes.where((t) => t != '__none__').length;
    final label = _clipboardFilteredTypes.isEmpty
        ? 'All types'
        : '$activeCount of $totalTypes';

    return MenuAnchor(
      style: MenuStyle(
        minimumSize: const WidgetStatePropertyAll(Size(280, 0)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        elevation: const WidgetStatePropertyAll(8),
        backgroundColor: const WidgetStatePropertyAll(
          Colors.white,
        ),
      ),
      builder: (context, controller, child) {
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            backgroundColor: Colors.white,
            side: BorderSide(
              color: controller.isOpen
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.filter_alt_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (activeCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$activeCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(
                controller.isOpen
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        );
      },
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'CONTENT TYPE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        if (_clipboardTypeEntries.isEmpty)
          MenuItemButton(
            onPressed: null,
            style: MenuItemButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              minimumSize: const Size(260, 48),
            ),
            child: const Text('No types available'),
          )
        else
          ..._clipboardTypeEntries.map((entry) {
            final typeLabel = entry.key;
            final isSelected = _clipboardFilteredTypes.isEmpty ||
                _clipboardFilteredTypes.contains(typeLabel);

            return MenuItemButton(
              style: MenuItemButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                minimumSize: const Size(260, 44),
              ),
              closeOnActivate: false,
              onPressed: () => _toggleTypeFilter(typeLabel),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleTypeFilter(typeLabel),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    typeLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  void _toggleDeviceFilter(String? deviceId) {
    if (deviceId == null) return;
    setState(() {
      if (_clipboardFilteredSourceDeviceIds.isEmpty) {
        final allIds = _clipboardSourceEntries
            .map((e) => e.key)
            .whereType<String>()
            .toSet();
        allIds.remove(deviceId);
        _clipboardFilteredSourceDeviceIds.addAll(allIds);
        if (_clipboardFilteredSourceDeviceIds.isEmpty) {
          _clipboardFilteredSourceDeviceIds.add('__none__');
        }
      } else {
        if (_clipboardFilteredSourceDeviceIds.contains(deviceId)) {
          _clipboardFilteredSourceDeviceIds.remove(deviceId);
          if (_clipboardFilteredSourceDeviceIds.isEmpty) {
            _clipboardFilteredSourceDeviceIds.add('__none__');
          }
        } else {
          _clipboardFilteredSourceDeviceIds.remove('__none__');
          _clipboardFilteredSourceDeviceIds.add(deviceId);
          final allIds = _clipboardSourceEntries
              .map((e) => e.key)
              .whereType<String>()
              .toSet();
          if (_clipboardFilteredSourceDeviceIds.containsAll(allIds)) {
            _clipboardFilteredSourceDeviceIds.clear();
          }
        }
      }
    });
  }

  void _toggleTypeFilter(String typeLabel) {
    setState(() {
      if (_clipboardFilteredTypes.isEmpty) {
        final allTypes = _clipboardTypeEntries.map((e) => e.key).toSet();
        allTypes.remove(typeLabel);
        _clipboardFilteredTypes.addAll(allTypes);
        if (_clipboardFilteredTypes.isEmpty) {
          _clipboardFilteredTypes.add('__none__');
        }
      } else {
        if (_clipboardFilteredTypes.contains(typeLabel)) {
          _clipboardFilteredTypes.remove(typeLabel);
          if (_clipboardFilteredTypes.isEmpty) {
            _clipboardFilteredTypes.add('__none__');
          }
        } else {
          _clipboardFilteredTypes.remove('__none__');
          _clipboardFilteredTypes.add(typeLabel);
          final allTypes = _clipboardTypeEntries.map((e) => e.key).toSet();
          if (_clipboardFilteredTypes.containsAll(allTypes)) {
            _clipboardFilteredTypes.clear();
          }
        }
      }
    });
  }

  List<Map<String, dynamic>> get _visibleClipboardOffers {
    return _clipboardOffers.where((offer) {
      final sourceDeviceId = offer['sourceDeviceId']?.toString();
      final isLocal =
          (_localDeviceId != null && sourceDeviceId == _localDeviceId) ||
              (widget.deviceId != null && sourceDeviceId == widget.deviceId);
      if (isLocal) return false;

      final mediaType = offer['contentType']?.toString() ??
          offer['mediaType']?.toString() ??
          '';
      final typeLabel = _clipboardTypeLabel(mediaType);

      final matchesDevice = _clipboardFilteredSourceDeviceIds.isEmpty ||
          (sourceDeviceId != null &&
              _clipboardFilteredSourceDeviceIds.contains(sourceDeviceId));

      final matchesType = _clipboardFilteredTypes.isEmpty ||
          _clipboardFilteredTypes.contains(typeLabel);

      return matchesDevice && matchesType;
    }).toList(growable: false);
  }

  List<MapEntry<String?, int>> get _clipboardSourceEntries {
    final counts = <String?, int>{};
    for (final offer in _clipboardOffers) {
      final sourceDeviceId = offer['sourceDeviceId']?.toString();
      final isLocal =
          (_localDeviceId != null && sourceDeviceId == _localDeviceId) ||
              (widget.deviceId != null && sourceDeviceId == widget.deviceId);
      if (isLocal) continue;
      counts[sourceDeviceId] = (counts[sourceDeviceId] ?? 0) + 1;
    }
    final entries = counts.entries.toList(growable: false);
    entries.sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      if (byCount != 0) {
        return byCount;
      }
      return _peerDisplayName(a.key).compareTo(_peerDisplayName(b.key));
    });
    return entries;
  }

  List<MapEntry<String, int>> get _clipboardTypeEntries {
    final counts = <String, int>{};
    for (final offer in _clipboardOffers) {
      final sourceDeviceId = offer['sourceDeviceId']?.toString();
      final isLocal =
          (_localDeviceId != null && sourceDeviceId == _localDeviceId) ||
              (widget.deviceId != null && sourceDeviceId == widget.deviceId);
      if (isLocal) continue;
      final mediaType = offer['contentType']?.toString() ??
          offer['mediaType']?.toString() ??
          '';
      final label = _clipboardTypeLabel(mediaType);
      counts[label] = (counts[label] ?? 0) + 1;
    }
    final entries = counts.entries.toList(growable: false);
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  Widget _buildClipboardOfferCard(ThemeData theme, Map<String, dynamic> offer) {
    final mediaType =
        offer['contentType']?.toString() ?? 'application/octet-stream';
    final sourceDeviceId = offer['sourceDeviceId']?.toString();
    final sizeLabel = _formatSize(offer['byteSize'] as num? ?? 0);
    final expiresAt = DateTime.tryParse(offer['expiresAt']?.toString() ?? '');
    final isExpired = expiresAt != null && expiresAt.isBefore(DateTime.now());
    final isText = mediaType.startsWith('text/');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(
              _clipboardSourceIcon(sourceDeviceId, mediaType),
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          _peerDisplayName(sourceDeviceId),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: isText
                                ? theme.colorScheme.surfaceContainerHigh
                                : const Color(0xFF6E3FB0)
                                    .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _clipboardTypeLabel(mediaType).toUpperCase(),
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: isText
                                  ? theme.colorScheme.onSurfaceVariant
                                  : const Color(0xFF6E3FB0),
                            ),
                          ),
                        ),
                      ],
                    ),
                    _buildClipboardTimeBadge(theme, expiresAt),
                  ],
                ),
                const SizedBox(height: 8),
                if (isText)
                  Text(
                    _clipboardPrimaryLabel(mediaType),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Container(
                    width: double.infinity,
                    constraints:
                        const BoxConstraints(maxWidth: 260, maxHeight: 120),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                      border:
                          Border.all(color: theme.colorScheme.outlineVariant),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      _mediaTypeIcon(mediaType),
                      size: 28,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Icon(
                          isExpired ? Icons.access_time : Icons.check_circle,
                          size: 14,
                          color: isExpired
                              ? theme.colorScheme.outline
                              : const Color(0xFF12744F),
                        ),
                        Text(
                          isExpired ? 'No longer available' : 'Auto-synced',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: isExpired
                                ? theme.colorScheme.onSurfaceVariant
                                : const Color(0xFF12744F),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '• $sizeLabel',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            RiftSnackbar.show(
                              context: context,
                              message: 'Copied to clipboard again',
                              type: RiftSnackbarType.info,
                            );
                          },
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text('Copy again'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.primary,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                          ),
                        ),
                        if (!isText)
                          TextButton.icon(
                            onPressed: () {
                              RiftSnackbar.show(
                                context: context,
                                message: 'File saved',
                                type: RiftSnackbarType.info,
                              );
                            },
                            icon: const Icon(Icons.download, size: 14),
                            label: const Text('Save as file'),
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  theme.colorScheme.onSurfaceVariant,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _clipboardTypeLabel(String mediaType) {
    if (mediaType.startsWith('image/')) {
      return 'Image';
    }
    if (mediaType.startsWith('text/')) {
      return 'Text';
    }
    if (mediaType.startsWith('video/')) {
      return 'Video';
    }
    if (mediaType.startsWith('audio/')) {
      return 'Audio';
    }
    return 'File';
  }

  IconData _clipboardSourceIcon(String? deviceId, String? mediaType) {
    final peer = _trustedPeers.cast<Map<String, dynamic>?>().firstWhere(
          (entry) => entry?['deviceId']?.toString() == deviceId,
          orElse: () => null,
        );
    final platform = peer?['platform']?.toString().toLowerCase();
    if (platform == 'android' || platform == 'ios') {
      return Icons.smartphone;
    }
    if (platform == 'macos' || platform == 'linux' || platform == 'windows') {
      return Icons.laptop_mac;
    }
    if (mediaType != null && mediaType.startsWith('image/')) {
      return Icons.image_outlined;
    }
    return Icons.devices_outlined;
  }

  Widget _buildClipboardTimeBadge(ThemeData theme, DateTime? expiresAt) {
    final label =
        expiresAt == null ? 'Unknown' : _formatRelativeTime(expiresAt);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _clipboardPrimaryLabel(String mediaType) {
    if (mediaType.startsWith('text/')) {
      return 'Encrypted text clip ready to fetch';
    }
    if (mediaType.startsWith('image/')) {
      return 'Image clipboard item';
    }
    if (mediaType.startsWith('video/')) {
      return 'Video clipboard item';
    }
    if (mediaType.startsWith('audio/')) {
      return 'Audio clipboard item';
    }
    return 'Clipboard file item';
  }

  String _formatRelativeTime(DateTime timestamp) {
    final now = DateTime.now().toUtc();
    final target = timestamp.toUtc();
    final difference = target.difference(now);
    final absDifference = difference.abs();

    String unitLabel;
    int value;
    if (absDifference.inSeconds < 60) {
      unitLabel = 's';
      value = absDifference.inSeconds;
    } else if (absDifference.inMinutes < 60) {
      unitLabel = 'm';
      value = absDifference.inMinutes;
    } else if (absDifference.inHours < 24) {
      unitLabel = 'h';
      value = absDifference.inHours;
    } else {
      unitLabel = 'd';
      value = absDifference.inDays;
    }

    if (value <= 0) {
      return 'now';
    }
    return difference.isNegative
        ? '$value$unitLabel ago'
        : 'in $value$unitLabel';
  }

  Widget _buildFileSendSection(ThemeData theme) {
    final peers = _fileCapablePeers;
    final activeOutgoingTransfers = _activeOutgoingTransfers;
    final queueItems = _sendQueue.items;
    final sentCount =
        queueItems.where((file) => file.status == SendQueueStatus.sent).length;
    final failedCount = queueItems
        .where((file) => file.status == SendQueueStatus.failed)
        .length;

    final effectiveSelectedIds = _selectedSendDeviceIds.isNotEmpty ||
            _hasUserModifiedSendDevices
        ? _selectedSendDeviceIds
        : peers.isNotEmpty
            ? <String>{peers.first['deviceId']?.toString() ?? ''}
            : <String>{};

    final hasSendableFiles = queueItems.any(
      (file) =>
          file.status == SendQueueStatus.queued ||
          file.status == SendQueueStatus.failed,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (activeOutgoingTransfers.isNotEmpty) ...[
          _buildOutgoingTransferBanner(theme, activeOutgoingTransfers),
          const SizedBox(height: 16),
        ],
        _buildSendControlsCard(
          theme,
          peers: peers,
          effectiveSelectedIds: effectiveSelectedIds,
          queueItems: queueItems,
          hasSendableFiles: hasSendableFiles,
        ),
        const SizedBox(height: 16),
        _buildTransferHubQueueCard(
          theme,
          peers: peers,
          activeOutgoingTransfers: activeOutgoingTransfers,
          sentCount: sentCount,
          failedCount: failedCount,
        ),
      ],
    );
  }

  Widget _buildSendControlsCard(
    ThemeData theme, {
    required List<Map<String, dynamic>> peers,
    required Set<String> effectiveSelectedIds,
    required List<SendQueueEntry> queueItems,
    required bool hasSendableFiles,
  }) {
    final totalSize = queueItems.fold<num>(
      0,
      (sum, f) => sum + f.byteSize,
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _addFilesToSendQueue,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Files'),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_upload_outlined,
                        size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      'Or drag files onto this window',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'SEND TO',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 8),
            if (peers.isEmpty)
              Text(
                'No trusted peer currently advertises file.transfer.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final isMobile = constraints.maxWidth < 600;
                  final chipWidgets = peers.map((peer) {
                    final deviceId = peer['deviceId']?.toString() ?? '';
                    final isSelected = effectiveSelectedIds.contains(deviceId);
                    final isOnline = peer['presence']?.toString() == 'online';
                    return _buildDeviceSelectChip(
                      theme,
                      label: _peerDisplayName(deviceId),
                      platform: peer['platform']?.toString(),
                      isSelected: isSelected,
                      isOnline: isOnline,
                      onTap: () =>
                          _toggleSendDevice(deviceId, effectiveSelectedIds),
                    );
                  }).toList();

                  if (isMobile) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: chipWidgets
                          .map((chip) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: chip,
                              ))
                          .toList(),
                    );
                  }

                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: chipWidgets,
                  );
                },
              ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 12,
              children: [
                if (queueItems.isEmpty)
                  Text(
                    'No files staged',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 12.5,
                    ),
                  )
                else
                  RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                      children: [
                        TextSpan(
                          text: '${queueItems.length} file${queueItems.length > 1 ? 's' : ''}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        TextSpan(
                          text: ' ready · ${_formatSize(totalSize)} total',
                        ),
                      ],
                    ),
                  ),
                FilledButton.icon(
                  onPressed: hasSendableFiles && effectiveSelectedIds.isNotEmpty
                      ? _sendStagedFilesToSelectedPeers
                      : null,
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  label: Text(
                    effectiveSelectedIds.isEmpty
                        ? 'Select a device'
                        : !hasSendableFiles
                            ? 'No files to send'
                            : 'Send to ${effectiveSelectedIds.length} device${effectiveSelectedIds.length > 1 ? 's' : ''}',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    disabledBackgroundColor:
                        theme.colorScheme.surfaceContainerHigh,
                    disabledForegroundColor: theme.colorScheme.outline,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fileExtension(String fileName) {
    final idx = fileName.lastIndexOf('.');
    return idx != -1 && idx < fileName.length - 1
        ? fileName.substring(idx + 1).toUpperCase()
        : 'FILE';
  }

  Widget _buildDeviceSelectChip(
    ThemeData theme, {
    required String label,
    required String? platform,
    required bool isSelected,
    required bool isOnline,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.06)
              : theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline
                    ? const Color(0xFF22C55E)
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            const SizedBox(width: 7),
            Icon(
              _platformIcon(platform),
              size: 16,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${_formatPlatformName(platform ?? '')} · ${isOnline ? 'Online' : 'Offline'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: isSelected
                  ? const Icon(Icons.check, size: 12, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildTransferHubHero(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Transfer Hub',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Monitor and manage secure file synchronizations.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildTransferHubQueueCard(
    ThemeData theme, {
    required List<Map<String, dynamic>> peers,
    required List<Map<String, dynamic>> activeOutgoingTransfers,
    required int sentCount,
    required int failedCount,
  }) {
    final fileTypes = _sendQueue.items
        .map((item) => _fileExtension(item.fileName))
        .toSet()
        .join(', ');

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Text(
                  'Send Queue',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  ' · ${_sendQueue.items.length} ITEM${_sendQueue.items.length != 1 ? 'S' : ''}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Text(
                  fileTypes.isEmpty ? 'EMPTY' : fileTypes,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_sendQueue.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No files staged for sending.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else ...[
                  ..._sendQueue.items.map(
                    (file) => _buildTransferQueueFileTile(theme, file),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferQueueFileTile(ThemeData theme, SendQueueEntry file) {
    final progress = file.byteSize <= 0
        ? 0.0
        : (file.bytesTransferred / file.byteSize).clamp(0, 1).toDouble();
    final canRetry = file.status == SendQueueStatus.failed;
    final canRetarget = _hasUnavailableTarget(file);
    final canCancel = file.status != SendQueueStatus.sent;

    final ext = _fileExtension(file.fileName);
    final targetText =
        file.targetDeviceId == null || file.targetDeviceId!.isEmpty
            ? null
            : 'Target: ${_peerDisplayName(file.targetDeviceId)}';
    final metaText = '${_formatSize(file.byteSize)} · $ext'
        '${targetText != null ? ' · $targetText' : ''}'
        '${file.errorMessage != null && file.errorMessage!.trim().isNotEmpty ? ' · ${file.errorMessage}' : ''}';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(
              _mediaTypeIcon(file.mediaType),
              size: 17,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.fileName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  metaText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: file.status == SendQueueStatus.failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (file.status == SendQueueStatus.sending) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: theme.colorScheme.surfaceContainer,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          _buildQueueStatusCapsule(theme, file.status),
          if (canCancel || canRetry || canRetarget) ...[
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canRetry) ...[
                  OutlinedButton(
                    onPressed: () => _retryFailedStagedFile(file),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: theme.colorScheme.primary),
                      foregroundColor: theme.colorScheme.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      minimumSize: const Size(0, 28),
                    ),
                    child: const Text('Retry', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 6),
                ],
                if (canRetarget && !canRetry) ...[
                  OutlinedButton(
                    onPressed: () => _chooseDeviceForStagedFile(file),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: theme.colorScheme.primary),
                      foregroundColor: theme.colorScheme.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                      minimumSize: const Size(0, 28),
                    ),
                    child: const Text('Retarget', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 6),
                ],
                if (canCancel)
                  OutlinedButton.icon(
                    onPressed: () => _cancelStagedFile(file),
                    icon: Icon(
                      file.status == SendQueueStatus.sending
                          ? Icons.stop_circle_outlined
                          : Icons.close,
                      size: 14,
                    ),
                    label: Text(
                      file.status == SendQueueStatus.sending
                          ? 'Cancel'
                          : 'Remove',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide.none,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                      minimumSize: const Size(0, 28),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildTransferHubIncomingCard(ThemeData theme) {
    final offers = _incomingFileOffers;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.move_to_inbox, color: theme.colorScheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Incoming',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (offers.isNotEmpty)
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: offers.isEmpty
                ? Text(
                    'No incoming file offers in this section.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : Column(
                    children: offers.take(3).map((offer) {
                      final sourceDeviceId =
                          offer['sourceDeviceId']?.toString();
                      final mediaType = offer['mediaType']?.toString() ??
                          'application/octet-stream';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceBright,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _mediaTypeIcon(mediaType),
                                  color: theme.colorScheme.tertiary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        offer['fileName']?.toString() ??
                                            'Unknown file',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                          color: theme.colorScheme.onSurface,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'From: ${_peerDisplayName(sourceDeviceId)} • ${_formatSize(offer['byteSize'] as num? ?? 0)}',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton(
                                    onPressed: () =>
                                        _acceptIncomingOffer(offer),
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          theme.colorScheme.primaryFixed,
                                      foregroundColor:
                                          theme.colorScheme.onPrimaryFixed,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 0),
                                      minimumSize: const Size(0, 32),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(4)),
                                    ),
                                    child: const Text('Save'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () =>
                                        _rejectIncomingOffer(offer),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 0),
                                      minimumSize: const Size(0, 32),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(4)),
                                    ),
                                    child: const Text('Reject'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(growable: false),
                  ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildTransferHubActivityCard(ThemeData theme) {
    final transfers = _fileTransfers.take(5).toList(growable: false);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.receipt_long, color: theme.colorScheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recent Activity',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(
                      () => _activeSection = _HistorySection.transferActivity,
                    );
                  },
                  child: const Text('View All'),
                ),
              ],
            ),
          ),
          if (transfers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No file transfer activity in this section.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Column(
              children: transfers
                  .map((transfer) => _buildTransferActivityRow(theme, transfer))
                  .toList(growable: false),
            ),
        ],
      ),
    );
  }

  Widget _buildTransferActivityRow(
    ThemeData theme,
    Map<String, dynamic> transfer,
  ) {
    final direction = transfer['direction']?.toString() ?? 'unknown';
    final isIncoming = direction == 'incoming';
    final state = transfer['state']?.toString() ?? 'pending';
    final byteSize = (transfer['byteSize'] as num?)?.toDouble() ?? 0;

    final timeStr = _formatRelativeTime(
        DateTime.tryParse(transfer['updatedAt']?.toString() ?? '') ??
            DateTime.now());

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: state.toLowerCase() == 'failed'
                        ? theme.colorScheme.errorContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    state.toLowerCase() == 'failed'
                        ? Icons.close
                        : (isIncoming
                            ? Icons.arrow_downward
                            : Icons.arrow_upward),
                    size: 16,
                    color: state.toLowerCase() == 'failed'
                        ? theme.colorScheme.onErrorContainer
                        : (isIncoming
                            ? theme.colorScheme.primary
                            : theme.colorScheme.tertiary),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        transfer['fileName']?.toString() ?? 'Unknown file',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _transferPeerSummary(transfer),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildTransferStatusBadge(
                theme,
                _transferStateLabel(state),
                tone: _transferStateBadgeTone(theme, state),
                foreground: _transferStateBadgeForeground(theme, state),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  timeStr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatSize(byteSize),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferStatusBadge(
    ThemeData theme,
    String label, {
    required Color tone,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildQueueStatusCapsule(ThemeData theme, SendQueueStatus status) {
    Color bg;
    Color fg;
    switch (status) {
      case SendQueueStatus.queued:
        bg = theme.colorScheme.surfaceContainerHigh;
        fg = theme.colorScheme.onSurfaceVariant;
        break;
      case SendQueueStatus.sending:
        bg = const Color(0xFF3636C5).withValues(alpha: 0.10);
        fg = const Color(0xFF3636C5);
        break;
      case SendQueueStatus.sent:
        bg = const Color(0xFF12744F).withValues(alpha: 0.10);
        fg = const Color(0xFF12744F);
        break;
      case SendQueueStatus.failed:
        bg = theme.colorScheme.errorContainer;
        fg = theme.colorScheme.error;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _sendQueueStatusLabel(status),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  String _sendQueueStatusLabel(SendQueueStatus status) {
    switch (status) {
      case SendQueueStatus.queued:
        return 'READY';
      case SendQueueStatus.sending:
        return 'SENDING';
      case SendQueueStatus.sent:
        return 'SENT';
      case SendQueueStatus.failed:
        return 'FAILED';
    }
  }

  // ignore: unused_element
  Color _sendQueueStatusColor(ThemeData theme, SendQueueStatus status) {
    switch (status) {
      case SendQueueStatus.queued:
        return theme.colorScheme.primary;
      case SendQueueStatus.sending:
        return theme.colorScheme.secondary;
      case SendQueueStatus.sent:
        return theme.colorScheme.tertiary;
      case SendQueueStatus.failed:
        return theme.colorScheme.error;
    }
  }

  Color _transferStateBadgeTone(ThemeData theme, String state) {
    switch (state.toLowerCase()) {
      case 'done':
        return theme.colorScheme.secondaryContainer;
      case 'failed':
        return theme.colorScheme.errorContainer;
      default:
        return theme.colorScheme.surfaceContainerHighest;
    }
  }

  Color _transferStateBadgeForeground(ThemeData theme, String state) {
    switch (state.toLowerCase()) {
      case 'done':
        return theme.colorScheme.onSecondaryContainer;
      case 'failed':
        return theme.colorScheme.onErrorContainer;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  Widget _buildOutgoingTransferBanner(
    ThemeData theme,
    List<Map<String, dynamic>> activeOutgoingTransfers,
  ) {
    final count = activeOutgoingTransfers.length;
    final primaryPeer = _peerDisplayName(
      activeOutgoingTransfers.first['peerDeviceId']?.toString(),
    );
    final uniquePeers = activeOutgoingTransfers
        .map((transfer) => transfer['peerDeviceId']?.toString() ?? '')
        .where((deviceId) => deviceId.isNotEmpty)
        .toSet()
        .length;
    final summary = uniquePeers > 1
        ? 'Now sending $count file(s) to $uniquePeers devices.'
        : 'Now sending $count file(s) to $primaryPeer.';

    double progress = 0.62;
    if (activeOutgoingTransfers.isNotEmpty) {
      final first = activeOutgoingTransfers.first;
      final transferred = (first['bytesTransferred'] as num?)?.toDouble();
      final total = (first['byteSize'] as num?)?.toDouble();
      if (transferred != null && total != null && total > 0) {
        progress = (transferred / total).clamp(0.0, 1.0);
      }
    }

    final pendingColor = const Color(0xFF3636C5);
    final pendingBg = pendingColor.withValues(alpha: 0.10);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: pendingBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.sync,
            size: 16,
            color: pendingColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: pendingColor,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 100,
            height: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: pendingColor.withValues(alpha: 0.20),
                valueColor: AlwaysStoppedAnimation<Color>(pendingColor),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${(progress * 100).toInt()}%',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: pendingColor,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              setState(() => _activeSection = _HistorySection.transferActivity);
            },
            style: TextButton.styleFrom(
              foregroundColor: pendingColor,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 26),
            ),
            child: const Text(
              'View Activity',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIncomingFileOffersSection(ThemeData theme) {
    final offers = _incomingFileOffers;
    if (offers.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 48),
        alignment: Alignment.center,
        child: Text(
          'No incoming file offers in this section.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    final allSelected =
        offers.isNotEmpty && _selectedIncomingOffers.length == offers.length;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          // Header Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border(
                  bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Checkbox(
                    value: allSelected,
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedIncomingOffers.addAll(
                              offers.map((o) => o['transferId'].toString()));
                        } else {
                          _selectedIncomingOffers.clear();
                        }
                      });
                    },
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    'SOURCE DEVICE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.secondary,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'DATA PACKAGE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.secondary,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'SIZE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.secondary,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Container(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'TIME',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.secondary,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Rows
          ...offers.map((offer) {
            final transferId = offer['transferId']?.toString() ?? '';
            final sourceDeviceId = offer['sourceDeviceId']?.toString() ?? '';
            final mediaType =
                offer['mediaType']?.toString() ?? 'application/octet-stream';
            final byteSize = (offer['byteSize'] as num?)?.toDouble() ?? 0;
            final timeStr = _formatRelativeTime(
              DateTime.tryParse(offer['createdAt']?.toString() ?? '') ??
                  DateTime.now(),
            );
            final isSelected = _selectedIncomingOffers.contains(transferId);

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.3)
                    : Colors.transparent,
                border: Border(
                    bottom:
                        BorderSide(color: theme.colorScheme.outlineVariant)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedIncomingOffers.add(transferId);
                          } else {
                            _selectedIncomingOffers.remove(transferId);
                          }
                        });
                      },
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            _platformIcon(offer['platform']?.toString()),
                            color: theme.colorScheme.primaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _peerDisplayName(sourceDeviceId),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: theme.colorScheme.onSurface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                sourceDeviceId.isEmpty
                                    ? 'Unknown Device'
                                    : 'Trusted',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.secondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offer['fileName']?.toString() ?? 'Unknown file',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                mediaType.split('/').last.toUpperCase(),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 10,
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      _formatSize(byteSize),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Container(
                      alignment: Alignment.centerRight,
                      child: Text(
                        timeStr,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTransferActivitySection(ThemeData theme) {
    final transfers = _fileTransfers;
    if (transfers.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 48),
        alignment: Alignment.center,
        child: Text(
          'No file transfer activity in this section.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    final toolbar = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.primary,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: () {},
            icon: const Icon(Icons.filter_list, size: 16),
            label: const Text('Filter Types'),
          ),
          Text(
            '${transfers.length} items • ${_activeOutgoingTransfers.length} active',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        toolbar,
        ...transfers.take(12).map((transfer) {
          final mediaType =
              transfer['mediaType']?.toString() ?? 'application/octet-stream';
          final byteSize = (transfer['byteSize'] as num?)?.toDouble() ?? 0;
          final transferred =
              (transfer['bytesTransferred'] as num?)?.toDouble() ?? 0;
          final state = transfer['state']?.toString() ?? 'pending';
          final direction = transfer['direction']?.toString() ?? 'unknown';
          final destinationPath = transfer['destinationPath']?.toString() ?? '';
          final progress = byteSize <= 0
              ? null
              : (transferred / byteSize).clamp(0, 1).toDouble();
          final stateColor = _transferStateColor(theme, state);
          final canOpenDestination = direction == 'incoming' &&
              destinationPath.trim().isNotEmpty &&
              state.toLowerCase() == 'done';
          return Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      direction == 'incoming' ? Icons.download : Icons.upload,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _mediaTypeIcon(mediaType),
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        transfer['fileName']?.toString() ?? 'Unknown file',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Text(
                      _transferStateLabel(state),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: stateColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_transferPeerSummary(transfer)} • $mediaType • ${_formatSize(byteSize)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (canOpenDestination) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Saved to: $destinationPath',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
                if (progress != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: state.toLowerCase() == 'failed' ? null : progress,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_formatSize(transferred)} / ${_formatSize(byteSize)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (transfer['failureReason'] != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    transfer['failureReason'].toString(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (canOpenDestination) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (_revealCompletedTransfersInFolder) ...[
                        OutlinedButton.icon(
                          onPressed: () => _openTransferDestination(
                            destinationPath,
                            revealInFolder: true,
                          ),
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Open Folder'),
                        ),
                        const SizedBox(width: 8),
                      ],
                      OutlinedButton.icon(
                        onPressed: () => _openTransferDestination(
                          destinationPath,
                          revealInFolder: false,
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open File'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
        }),
      ],
    );
  }
}
