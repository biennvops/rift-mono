import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../src/platform/android_shell.dart';
import '../src/platform/macos_send_files.dart';
import '../src/platform/notification_route.dart';

enum _HistorySection {
  clipboard,
  notifications,
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
  final bool? exportCompletedTransfersOverride;
  final Future<void> Function(String path)? openFileOverride;
  final Future<void> Function(String path)? exportFileOverride;
  final bool? iosClipboardActionsOverride;
  final Future<String?> Function()? readClipboardTextOverride;
  final Future<void> Function(String text)? writeClipboardTextOverride;
  final ValueNotifier<String?>? routeNotifier;
  final ValueNotifier<String?>? sharedClipboardTextNotifier;

  const ClipboardTransferScreen({
    super.key,
    this.deviceId,
    this.displayName,
    this.pickSendFilesOverride,
    this.revealCompletedTransfersInFolderOverride,
    this.exportCompletedTransfersOverride,
    this.openFileOverride,
    this.exportFileOverride,
    this.iosClipboardActionsOverride,
    this.readClipboardTextOverride,
    this.writeClipboardTextOverride,
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
  final List<Map<String, dynamic>> _notifications = [];
  final List<Map<String, dynamic>> _incomingFileOffers = [];
  final List<Map<String, dynamic>> _fileTransfers = [];
  final List<Map<String, dynamic>> _trustedPeers = [];
  final Set<String> _hiddenOfferIds = <String>{};
  final Set<String> _legacySendingFilePeerIds = <String>{};

  StreamSubscription<Map<String, dynamic>>? _clipboardOfferSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardExpiredSub;
  StreamSubscription<Map<String, dynamic>>? _notificationPostedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationUpdatedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationRemovedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationActionResultSub;
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileProgressSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<bool>? _connectionChangedSub;

  bool _isRefreshing = false;
  bool _isRefreshingNotifications = false;
  bool _isRefreshingFileOffers = false;
  bool _isRefreshingTransfers = false;
  bool _isRefreshingPeers = false;
  _HistorySection _activeSection = _HistorySection.clipboard;

  bool get _revealCompletedTransfersInFolder =>
      widget.revealCompletedTransfersInFolderOverride ??
      shouldRevealCompletedTransferDestination();
  bool get _exportCompletedTransfers =>
      widget.exportCompletedTransfersOverride ?? Platform.isIOS;
  bool get _iosClipboardActions =>
      widget.iosClipboardActionsOverride ?? Platform.isIOS;
  late final SendQueueController _sendQueueController;
  SendQueueController get _sendQueue => _sendQueueController;
  SendQueueModeCoordinator get _queueMode =>
      SendQueueModeCoordinator(_sendQueue, _legacyQueueCoordinator);

  @override
  void initState() {
    super.initState();
    _sendQueueController = context.read<SendQueueController>();
    _sendQueueController.addListener(_handleSendQueueChanged);
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
    _sendQueueController.removeListener(_handleSendQueueChanged);
    widget.routeNotifier?.removeListener(_handleExternalRoute);
    _clipboardOfferSub?.cancel();
    _clipboardExpiredSub?.cancel();
    _notificationPostedSub?.cancel();
    _notificationUpdatedSub?.cancel();
    _notificationRemovedSub?.cancel();
    _notificationActionResultSub?.cancel();
    _fileOfferSub?.cancel();
    _fileProgressSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    _trustChangedSub?.cancel();
    _connectionChangedSub?.cancel();
    super.dispose();
  }

  void _handleSendQueueChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _handleExternalRoute() {
    final route = widget.routeNotifier?.value;
    if (route == null || !mounted) {
      return;
    }

    final nextSection = switch (route) {
      NotificationRoute.historyClipboard => _HistorySection.clipboard,
      NotificationRoute.historyNotifications => _HistorySection.notifications,
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
    _notificationPostedSub = client.onNotificationPosted.listen((event) {
      if (mounted) {
        unawaited(_refreshNotifications());
      }
    });
    _notificationUpdatedSub = client.onNotificationUpdated.listen((_) {
      if (mounted) {
        unawaited(_refreshNotifications());
      }
    });
    _notificationRemovedSub = client.onNotificationRemoved.listen((_) {
      if (mounted) {
        unawaited(_refreshNotifications());
      }
    });
    _notificationActionResultSub =
        client.onNotificationActionResult.listen((_) {
      if (mounted) {
        unawaited(_refreshNotifications());
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
        _retainTerminalTransfer(event);
        unawaited(_refreshFileOffers());
        unawaited(_refreshTransfers());
      }
    });
    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      unawaited(_handleLegacyTransferFailed(event));
      if (mounted) {
        _retainTerminalTransfer(event);
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
        _refreshClipboardOffers(),
        _refreshNotifications(),
        _refreshFileOffers(),
        _refreshTransfers(),
        _refreshTrustedPeers(),
      ]);
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
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
        return (offerId == null || !_hiddenOfferIds.contains(offerId)) &&
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
    setState(() => _isRefreshingFileOffers = true);
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
    } finally {
      if (mounted) {
        setState(() => _isRefreshingFileOffers = false);
      }
    }
  }

  Future<void> _refreshNotifications() async {
    final client = context.read<JsonRpcRiftClient>();
    setState(() => _isRefreshingNotifications = true);
    try {
      final result = await client.listNotifications();
      final notifications = List<Map<String, dynamic>>.from(
        (result['notifications'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ).where((record) {
        final sourceDeviceId = record['sourceDeviceId']?.toString();
        return _matchesDeviceFilter(sourceDeviceId);
      }).toList(growable: false);

      notifications.sort((a, b) {
        final aTime = DateTime.tryParse(a['postedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = DateTime.tryParse(b['postedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

      if (!mounted) return;
      setState(() {
        _notifications
          ..clear()
          ..addAll(notifications.take(20));
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) {
        setState(() => _isRefreshingNotifications = false);
      }
    }
  }

  Future<void> _refreshTransfers() async {
    final client = context.read<JsonRpcRiftClient>();
    setState(() => _isRefreshingTransfers = true);
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
      final listedTransferIds = transfers
          .map((transfer) => transfer['transferId']?.toString())
          .whereType<String>()
          .toSet();
      final retainedTerminalTransfers = _fileTransfers.where((transfer) {
        final transferId = transfer['transferId']?.toString();
        return _isTerminalTransfer(transfer) &&
            (transferId == null || !listedTransferIds.contains(transferId));
      }).toList(growable: false);
      setState(() {
        _fileTransfers
          ..clear()
          ..addAll(transfers)
          ..addAll(retainedTerminalTransfers);
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) {
        setState(() => _isRefreshingTransfers = false);
      }
    }
  }

  bool _isTerminalTransfer(Map<String, dynamic> transfer) {
    final state = transfer['state']?.toString().toLowerCase();
    return state == 'done' || state == 'failed' || state == 'cancelled';
  }

  void _retainTerminalTransfer(Map<String, dynamic> event) {
    if (!_matchesDeviceFilter(event['peerDeviceId']?.toString())) {
      return;
    }
    final transferId = event['transferId']?.toString();
    setState(() {
      if (transferId != null) {
        _fileTransfers.removeWhere(
          (transfer) => transfer['transferId']?.toString() == transferId,
        );
      }
      _fileTransfers.insert(0, Map<String, dynamic>.from(event));
    });
  }

  Future<void> _refreshTrustedPeers() async {
    final client = context.read<JsonRpcRiftClient>();
    setState(() => _isRefreshingPeers = true);
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
      if (mounted) {
        setState(() => _isRefreshingPeers = false);
      }
    }
  }

  String _peerDisplayName(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return 'Unknown device';
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

  Future<void> _sendClipboardText() async {
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<JsonRpcRiftClient>();
    try {
      final text = widget.readClipboardTextOverride != null
          ? await widget.readClipboardTextOverride!()
          : (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text == null || text.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('The clipboard has no text to send.')),
        );
        return;
      }

      final bytes = utf8.encode(text);
      await client.notifyClipboardChange(
        contentType: 'text/plain',
        byteSize: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        contentBase64: base64Encode(bytes),
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Clipboard sent to trusted devices.')),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Could not send clipboard: '
            '${JsonRpcRiftClient.formatDisplayError(error)}',
          ),
        ),
      );
    }
  }

  Future<void> _copyClipboardOffer(Map<String, dynamic> offer) async {
    final messenger = ScaffoldMessenger.of(context);
    final offerId = offer['offerId']?.toString();
    if (offerId == null || offerId.isEmpty) return;

    try {
      final result = await context
          .read<JsonRpcRiftClient>()
          .fetchClipboardContent(offerId);
      if (result['verified'] != true) {
        throw StateError('Clipboard content could not be verified.');
      }
      final contentBase64 = result['contentBase64']?.toString();
      if (contentBase64 == null || contentBase64.isEmpty) {
        throw StateError('Clipboard content was empty.');
      }
      final text = utf8.decode(base64Decode(contentBase64));
      if (widget.writeClipboardTextOverride != null) {
        await widget.writeClipboardTextOverride!(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Copied to clipboard.')),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not copy clipboard item: $error')),
      );
    }
  }

  Future<void> _performNotificationAction(
    Map<String, dynamic> notification,
    String action,
  ) async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      await client.performNotificationAction(
        notificationId: notification['notificationId']?.toString() ?? '',
        action: action,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'open'
                ? 'Notification opened on Android.'
                : 'Notification dismissed on Android.',
          ),
        ),
      );
      unawaited(_refreshNotifications());
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(error))),
      );
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
      final capabilities = List<String>.from(
        (peer['capabilities'] as List? ?? const <dynamic>[]).map(
          (item) => item.toString(),
        ),
      );
      return trustState == 'trusted' && capabilities.contains('file.transfer');
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

            return AlertDialog(
              title: const Text('Send File'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: pathController,
                      decoration: const InputDecoration(
                        labelText: 'Local path',
                        hintText: '/home/you/Downloads/example.mp4',
                      ),
                      autofocus: true,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Display file name (optional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: typeController,
                      decoration: const InputDecoration(
                        labelText: 'Media type',
                      ),
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
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
                  onPressed: submit,
                  child: const Text('Send'),
                ),
              ],
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
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Could not read ${pickResult.skippedFileNames.length} selected file(s).',
            ),
          ),
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
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No new file was added to the send queue.'),
        ),
      );
      return;
    }

    setState(() {
      if (switchToSendSection) {
        _activeSection = _HistorySection.send;
      }
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          [
            '$successPrefix ${result.added} file(s) in the send queue.',
            if (result.skipped > 0)
              'Skipped ${result.skipped} duplicate/unavailable item(s).',
            if (skippedUnreadableCount > 0)
              'Could not read $skippedUnreadableCount selected file(s).',
          ].join(' '),
        ),
      ),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No queued file is ready to send to ${_peerDisplayName(deviceId)}.',
          ),
        ),
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
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'No file was submitted to ${_peerDisplayName(deviceId)}.',
            ),
          ),
        );
      }
      await _refreshTransfers();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(e))),
      );
    } finally {
      if (mounted && isLegacyMode) {
        setState(() => _legacySendingFilePeerIds.remove(deviceId));
      }
    }
  }

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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            file.status == SendQueueStatus.sending
                ? 'Cancelled ${file.fileName}.'
                : 'Removed ${file.fileName} from the queue.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(error))),
      );
    }
  }

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
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'File moved back to queue. Choose a peer to send it again.',
            ),
          ),
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
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '${_peerDisplayName(peerDeviceId)} is no longer available for file transfer.',
            ),
          ),
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
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Retry queued for ${file.fileName}.'
              : 'Retry failed for ${file.fileName}.',
        ),
      ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Choose a device below to send ${file.fileName} again.',
          ),
        ),
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
      } else if (widget.openFileOverride != null) {
        await widget.openFileOverride!(destinationPath);
      } else {
        await openFilePath(destinationPath);
      }
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open saved file: $error')),
      );
    }
  }

  Future<void> _exportTransferDestination(String destinationPath) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (widget.exportFileOverride != null) {
        await widget.exportFileOverride!(destinationPath);
      } else {
        await exportFilePath(destinationPath);
      }
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export saved file: $error')),
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

            return AlertDialog(
              title: const Text('Save Incoming File'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: destinationController,
                      decoration: const InputDecoration(
                        labelText: 'Destination path',
                      ),
                      autofocus: true,
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
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
                  onPressed: submit,
                  child: const Text('Accept'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String?> _pickDestinationPath(String suggestedFileName) async {
    if (Platform.isAndroid) {
      final prepared =
          await AndroidShell.prepareIncomingDownload(suggestedFileName);
      return prepared?['stagingPath']?.toString();
    }

    try {
      final defaultPath = await _defaultDestinationPath(suggestedFileName);
      if (Platform.isIOS) {
        return defaultPath;
      }
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
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (destinationPath == null || destinationPath.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text('Could not resolve an iOS save location.')),
      );
      return;
    }

    messenger.showSnackBar(
      SnackBar(content: Text('Saving to $destinationPath...')),
    );
    try {
      await context
          .read<JsonRpcRiftClient>()
          .acceptFileOffer(
            transferId: transferId,
            destinationPath: destinationPath,
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _activeSection = _HistorySection.transferActivity;
      });
      await _refreshFileOffers();
      await _refreshTransfers();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(e))),
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
      messenger.showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(e))),
      );
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
    final title = widget.displayName != null && widget.displayName!.isNotEmpty
        ? 'History - ${widget.displayName}'
        : 'History';

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.primary,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: theme.colorScheme.outlineVariant, height: 1),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
    final activeTransferCount = _activeOutgoingTransfers.length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildSectionChip(theme, _HistorySection.clipboard, 'Clipboard'),
          const SizedBox(width: 8),
          _buildSectionChip(
            theme,
            _HistorySection.notifications,
            'Notifications',
          ),
          const SizedBox(width: 8),
          _buildSectionChip(theme, _HistorySection.send, 'Send File'),
          const SizedBox(width: 8),
          _buildSectionChip(
            theme,
            _HistorySection.incomingOffers,
            'Incoming Offers',
          ),
          const SizedBox(width: 8),
          _buildSectionChip(
            theme,
            _HistorySection.transferActivity,
            'Transfer Activity',
            badgeCount: activeTransferCount > 0 ? activeTransferCount : null,
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
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (_activeSection == section) return;
        setState(() => _activeSection = section);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: isSelected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (badgeCount != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.onPrimary.withValues(alpha: 0.18)
                      : theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$badgeCount',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isSelected
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActiveSection(ThemeData theme) {
    switch (_activeSection) {
      case _HistorySection.clipboard:
        return _buildClipboardHistorySection(theme);
      case _HistorySection.notifications:
        return _buildNotificationsSection(theme);
      case _HistorySection.send:
        return _buildFileSendSection(theme);
      case _HistorySection.incomingOffers:
        return _buildIncomingFileOffersSection(theme);
      case _HistorySection.transferActivity:
        return _buildTransferActivitySection(theme);
    }
  }

  Widget _buildClipboardHistorySection(ThemeData theme) {
    if (_clipboardOffers.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_iosClipboardActions) ...[
            FilledButton.icon(
              onPressed: _sendClipboardText,
              icon: const Icon(Icons.send),
              label: const Text('Send Clipboard'),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            'No recent clipboard items from trusted devices yet.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_iosClipboardActions) ...[
          FilledButton.icon(
            onPressed: _sendClipboardText,
            icon: const Icon(Icons.send),
            label: const Text('Send Clipboard'),
          ),
          const SizedBox(height: 16),
        ],
        ..._clipboardOffers.map((offer) {
          final sourceDeviceId = offer['sourceDeviceId']?.toString();
          final contentType = offer['contentType']?.toString() ?? '';
          final isImage = contentType.startsWith('image/');
          final mediaLabel = isImage ? 'Image' : 'Text';
          final expiresAt =
              DateTime.tryParse(offer['expiresAt']?.toString() ?? '');
          final expiresLabel = expiresAt == null
              ? null
              : 'Expires ${_formatRelativeTime(expiresAt)}';

          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isImage ? Icons.image : Icons.notes,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _peerDisplayName(sourceDeviceId),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$mediaLabel • ${_formatSize(offer['byteSize'] as num? ?? 0)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (expiresLabel != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          expiresLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (_iosClipboardActions && !isImage) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => _copyClipboardOffer(offer),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
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

  Widget _buildNotificationsSection(ThemeData theme) {
    return _buildSectionCard(
      theme: theme,
      title: 'Android Notifications',
      subtitle:
          'Mirrored from trusted Android devices. Open and dismiss actions are sent back to Android.',
      isLoading: _isRefreshingNotifications,
      onRefresh: _refreshNotifications,
      child: _notifications.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No mirrored Android notifications yet.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Column(
              children: _notifications.map((notification) {
                final title = notification['title']?.toString().trim();
                final body = notification['bodyPreview']?.toString().trim();
                final appName = notification['appName']?.toString() ?? 'App';
                final packageName = notification['packageName']?.toString() ??
                    'unknown.package';
                final sourceName = _peerDisplayName(
                    notification['sourceDeviceId']?.toString());
                final isRemoved = notification['isRemoved'] == true;
                final canOpen =
                    !isRemoved && notification['isOpenable'] == true;
                final canDismiss =
                    !isRemoved && notification['isDismissible'] == true;

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title == null || title.isEmpty ? appName : title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '$appName • $packageName • $sourceName',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (body != null && body.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(body),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: canOpen
                                  ? () => _performNotificationAction(
                                        notification,
                                        'open',
                                      )
                                  : null,
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Open'),
                            ),
                            OutlinedButton.icon(
                              onPressed: canDismiss
                                  ? () => _performNotificationAction(
                                        notification,
                                        'dismiss',
                                      )
                                  : null,
                              icon: const Icon(Icons.close),
                              label: Text(isRemoved ? 'Removed' : 'Dismiss'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(growable: false),
            ),
    );
  }

  Widget _buildFileSendSection(ThemeData theme) {
    final peers = _fileCapablePeers;
    final activeOutgoingTransfers = _activeOutgoingTransfers;
    return _buildSectionCard(
      theme: theme,
      title: 'Send File / Video',
      subtitle:
          'Hai bên đều có thể chủ động gửi. Mục này chỉ hiện peer đang trusted và có capability file.transfer.',
      isLoading: _isRefreshingPeers,
      onRefresh: _refreshTrustedPeers,
      child: Column(
        children: [
          if (activeOutgoingTransfers.isNotEmpty) ...[
            _buildOutgoingTransferBanner(theme, activeOutgoingTransfers),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _addFilesToSendQueue,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Files'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _sendQueue.items.any(
                  (file) => file.status == SendQueueStatus.sent,
                )
                    ? () => unawaited(_clearFinishedStagedFiles())
                    : null,
                child: const Text('Clear Sent'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildStagedFilesList(theme),
          const SizedBox(height: 12),
          if (peers.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'No trusted peer currently advertises file.transfer. Staged files will remain in the queue until a compatible peer is available.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...peers.map((peer) {
              final deviceId = peer['deviceId']?.toString();
              final showSendingSpinner = deviceId != null &&
                  _legacySendingFilePeerIds.contains(deviceId);
              final isSending = deviceId != null &&
                  (showSendingSpinner ||
                      _hasActiveOutgoingTransferForPeer(deviceId));
              final summary = deviceId == null || deviceId.isEmpty
                  ? const SendQueuePeerSummary(
                      eligibleCount: 0,
                      unassignedCount: 0,
                      waitingCount: 0,
                      failedCount: 0,
                    )
                  : _peerQueueSummary(deviceId);
              return Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      _platformIcon(peer['platform']?.toString()),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _peerDisplayName(deviceId),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            peer['platform']?.toString().toUpperCase() ??
                                'DEVICE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            summary.detailLabel(),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: isSending || summary.eligibleCount == 0
                          ? null
                          : () => _sendStagedFilesToPeer(peer),
                      icon: showSendingSpinner
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              isSending ? Icons.sync : Icons.upload_file,
                            ),
                      label: Text(
                        isSending ? 'Sending...' : summary.actionLabel(),
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.secondary.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.sync,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              setState(() => _activeSection = _HistorySection.transferActivity);
            },
            child: const Text('View Activity'),
          ),
        ],
      ),
    );
  }

  Widget _buildStagedFilesList(ThemeData theme) {
    return SendQueuePanel(
      items: _sendQueue.items
          .map(
            (file) => SendQueueItemData(
              fileName: file.fileName,
              mediaType: file.mediaType,
              byteSize: file.byteSize,
              bytesTransferred: file.bytesTransferred,
              status: file.status,
              targetLabel:
                  file.targetDeviceId == null || file.targetDeviceId!.isEmpty
                      ? null
                      : _peerDisplayName(file.targetDeviceId),
              errorMessage: file.errorMessage,
              isWaitingForReconnect: file.autoRetryWhenPeerAvailable,
              canRetarget: _hasUnavailableTarget(file),
            ),
          )
          .toList(growable: false),
      onCancel: (index) => _cancelStagedFile(_sendQueue.items[index]),
      onRetry: (index) => _retryFailedStagedFile(_sendQueue.items[index]),
      onRetarget: (index) =>
          _chooseDeviceForStagedFile(_sendQueue.items[index]),
    );
  }

  Widget _buildIncomingFileOffersSection(ThemeData theme) {
    final offers = _incomingFileOffers;
    return _buildSectionCard(
      theme: theme,
      title: 'Incoming Offers',
      isLoading: _isRefreshingFileOffers,
      onRefresh: _refreshFileOffers,
      child: offers.isEmpty
          ? Text(
              'Không có lời mời nhận file/video trong bộ lọc này.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              children: offers.map((offer) {
                final sourceDeviceId = offer['sourceDeviceId']?.toString();
                final mediaType = offer['mediaType']?.toString() ??
                    'application/octet-stream';
                return Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _mediaTypeIcon(mediaType),
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  offer['fileName']?.toString() ??
                                      'Unknown file',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                Text(
                                  '${_peerDisplayName(sourceDeviceId)} • $mediaType • ${_formatSize(offer['byteSize'] as num? ?? 0)}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
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
                            child: OutlinedButton(
                              onPressed: () => _rejectIncomingOffer(offer),
                              child: const Text('Reject'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _acceptIncomingOffer(offer),
                              child: const Text('Save'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }).toList(growable: false),
            ),
    );
  }

  Widget _buildTransferActivitySection(ThemeData theme) {
    final transfers = _fileTransfers;
    return _buildSectionCard(
      theme: theme,
      title: 'Transfer Activity',
      isLoading: _isRefreshingTransfers,
      onRefresh: _refreshTransfers,
      child: transfers.isEmpty
          ? Text(
              'Không có hoạt động file/video trong bộ lọc này.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              children: transfers.take(12).map((transfer) {
                final mediaType = transfer['mediaType']?.toString() ??
                    'application/octet-stream';
                final byteSize =
                    (transfer['byteSize'] as num?)?.toDouble() ?? 0;
                final transferred =
                    (transfer['bytesTransferred'] as num?)?.toDouble() ?? 0;
                final state = transfer['state']?.toString() ?? 'pending';
                final direction =
                    transfer['direction']?.toString() ?? 'unknown';
                final destinationPath =
                    transfer['destinationPath']?.toString() ?? '';
                final progress = byteSize <= 0
                    ? null
                    : (transferred / byteSize).clamp(0, 1).toDouble();
                final stateColor = _transferStateColor(theme, state);
                final canOpenDestination = direction == 'incoming' &&
                    destinationPath.trim().isNotEmpty &&
                    state.toLowerCase() == 'done';
                return Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            direction == 'incoming'
                                ? Icons.download
                                : Icons.upload,
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
                              transfer['fileName']?.toString() ??
                                  'Unknown file',
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
                          value:
                              state.toLowerCase() == 'failed' ? null : progress,
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
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (_revealCompletedTransfersInFolder)
                              OutlinedButton.icon(
                                onPressed: () => _openTransferDestination(
                                  destinationPath,
                                  revealInFolder: true,
                                ),
                                icon: const Icon(Icons.folder_open),
                                label: const Text('Open Folder'),
                              ),
                            OutlinedButton.icon(
                              onPressed: () => _openTransferDestination(
                                destinationPath,
                                revealInFolder: false,
                              ),
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Open File'),
                            ),
                            if (_exportCompletedTransfers)
                              OutlinedButton.icon(
                                onPressed: () => _exportTransferDestination(
                                  destinationPath,
                                ),
                                icon: const Icon(Icons.ios_share),
                                label: const Text('Export'),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              }).toList(growable: false),
            ),
    );
  }

  Widget _buildSectionCard({
    required ThemeData theme,
    required String title,
    String? subtitle,
    required Widget child,
    required bool isLoading,
    required Future<void> Function() onRefresh,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              if (isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh $title',
                ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
