import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../src/file_transfer/file_storage.dart';
import '../src/file_transfer/send_queue_panel.dart';
import '../src/ipc/json_rpc_client.dart';
import '../src/platform/notification_route.dart';

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
  final ValueNotifier<List<Map<String, String>>?>? sharedSendRequestsNotifier;

  const ClipboardTransferScreen({
    super.key,
    this.deviceId,
    this.displayName,
    this.pickSendFilesOverride,
    this.revealCompletedTransfersInFolderOverride,
    this.routeNotifier,
    this.sharedSendRequestsNotifier,
  });

  @override
  State<ClipboardTransferScreen> createState() =>
      _ClipboardTransferScreenState();
}

class _ClipboardTransferScreenState extends State<ClipboardTransferScreen> {
  final List<Map<String, dynamic>> _clipboardOffers = [];
  final List<Map<String, dynamic>> _incomingFileOffers = [];
  final List<Map<String, dynamic>> _fileTransfers = [];
  final List<Map<String, dynamic>> _trustedPeers = [];
  final List<_StagedSendFile> _stagedFiles = [];
  final Set<String> _hiddenOfferIds = <String>{};
  final Set<String> _sendingFilePeerIds = <String>{};

  StreamSubscription<Map<String, dynamic>>? _clipboardOfferSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardExpiredSub;
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileProgressSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;

  bool _isRefreshing = false;
  bool _isRefreshingFileOffers = false;
  bool _isRefreshingTransfers = false;
  bool _isRefreshingPeers = false;
  _HistorySection _activeSection = _HistorySection.clipboard;

  bool get _revealCompletedTransfersInFolder =>
      widget.revealCompletedTransfersInFolderOverride ??
      shouldRevealCompletedTransferDestination();

  @override
  void initState() {
    super.initState();
    widget.routeNotifier?.addListener(_handleExternalRoute);
    widget.sharedSendRequestsNotifier?.addListener(_handleExternalSharedSend);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindStreams();
      _refreshAll();
      _handleExternalSharedSend();
    });
  }

  @override
  void dispose() {
    widget.routeNotifier?.removeListener(_handleExternalRoute);
    widget.sharedSendRequestsNotifier
        ?.removeListener(_handleExternalSharedSend);
    _clipboardOfferSub?.cancel();
    _clipboardExpiredSub?.cancel();
    _fileOfferSub?.cancel();
    _fileProgressSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    _trustChangedSub?.cancel();
    super.dispose();
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

  void _handleExternalSharedSend() {
    final requests = widget.sharedSendRequestsNotifier?.value;
    if (requests == null || requests.isEmpty || !mounted) {
      return;
    }
    widget.sharedSendRequestsNotifier?.value = null;
    unawaited(
      _queueSendRequests(
        requests,
        switchToSendSection: true,
        successPrefix: 'Ready to send',
      ),
    );
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
      _applyTransferProgress(event);
      if (mounted) {
        unawaited(_refreshTransfers());
      }
    });
    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      _applyTransferCompleted(event);
      if (mounted) {
        unawaited(_refreshFileOffers());
        unawaited(_refreshTransfers());
      }
    });
    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      _applyTransferFailed(event);
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
  }

  Future<void> _refreshAll() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await Future.wait<void>([
        _refreshClipboardOffers(),
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
      setState(() {
        _fileTransfers
          ..clear()
          ..addAll(transfers);
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) {
        setState(() => _isRefreshingTransfers = false);
      }
    }
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
    });
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

    setState(() {
      staged.status = SendQueueStatus.failed;
      staged.errorMessage =
          event['message']?.toString() ?? event['failureReason']?.toString();
    });
  }

  _StagedSendFile? _findStagedFileByTransferId(String transferId) {
    for (final staged in _stagedFiles) {
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
    var added = 0;
    var skipped = 0;
    final stagedToAdd = <_StagedSendFile>[];
    for (final request in requests) {
      final localPath = request['localPath'];
      if (localPath == null || localPath.isEmpty) {
        skipped += 1;
        continue;
      }
      if (_stagedFiles.any((file) => file.localPath == localPath)) {
        skipped += 1;
        continue;
      }

      final file = File(localPath);
      if (!await file.exists()) {
        skipped += 1;
        continue;
      }

      stagedToAdd.add(
        _StagedSendFile(
          localPath: localPath,
          fileName: request['fileName']?.isNotEmpty == true
              ? request['fileName']!
              : localPath.split(Platform.pathSeparator).last,
          mediaType: request['mediaType']?.isNotEmpty == true
              ? request['mediaType']!
              : 'application/octet-stream',
          byteSize: await file.length(),
        ),
      );
      added += 1;
    }

    if (stagedToAdd.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No new file was added to the send queue.'),
        ),
      );
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _stagedFiles.addAll(stagedToAdd);
      if (switchToSendSection) {
        _activeSection = _HistorySection.send;
      }
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          [
            '$successPrefix $added file(s) in the send queue.',
            if (skipped > 0) 'Skipped $skipped duplicate/unavailable item(s).',
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
    final queuedFiles = _stagedFiles
        .where(
          (file) =>
              file.status == SendQueueStatus.queued ||
              file.status == SendQueueStatus.failed,
        )
        .toList(growable: false);
    if (queuedFiles.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No queued file is ready to send.')),
      );
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sendingFilePeerIds.add(deviceId));

    try {
      var submitted = 0;
      for (final staged in queuedFiles) {
        if (!mounted) return;
        if (await _submitStagedFileToPeer(
          client: client,
          staged: staged,
          deviceId: deviceId,
        )) {
          submitted += 1;
        }
      }
      if (!mounted) return;
      if (submitted > 0) {
        setState(() => _activeSection = _HistorySection.transferActivity);
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            submitted == 0
                ? 'No file was submitted to ${_peerDisplayName(deviceId)}.'
                : 'Sending $submitted file(s) to ${_peerDisplayName(deviceId)}. Track progress in Transfer Activity.',
          ),
        ),
      );
      await _refreshTransfers();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(e))),
      );
    } finally {
      if (mounted) {
        setState(() => _sendingFilePeerIds.remove(deviceId));
      }
    }
  }

  Future<bool> _submitStagedFileToPeer({
    required JsonRpcRiftClient client,
    required _StagedSendFile staged,
    required String deviceId,
  }) async {
    if (!mounted) return false;
    setState(() {
      staged.status = SendQueueStatus.sending;
      staged.errorMessage = null;
      staged.targetDeviceId = deviceId;
      staged.bytesTransferred = 0;
    });
    try {
      final result = await client.offerFile(
        targetDeviceId: deviceId,
        localPath: staged.localPath,
        fileName: staged.fileName,
        mediaType: staged.mediaType,
      );
      if (!mounted) return false;
      setState(() {
        staged.transferId = result['transferId']?.toString();
        staged.operationId = result['operationId']?.toString();
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        staged.status = SendQueueStatus.failed;
        staged.errorMessage = JsonRpcRiftClient.formatDisplayError(error);
      });
      return false;
    }
  }

  void _removeStagedFile(_StagedSendFile file) {
    setState(() {
      _stagedFiles.remove(file);
    });
  }

  void _clearFinishedStagedFiles() {
    setState(() {
      _stagedFiles.removeWhere(
        (file) => file.status == SendQueueStatus.sent,
      );
    });
  }

  Future<void> _retryFailedStagedFile(_StagedSendFile file) async {
    final messenger = ScaffoldMessenger.of(context);
    final deviceId = file.targetDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      setState(() {
        file.status = SendQueueStatus.queued;
        file.errorMessage = null;
      });
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'File moved back to queue. Choose a peer to send it again.',
          ),
        ),
      );
      return;
    }

    final peerExists = _fileCapablePeers.any(
      (candidate) => candidate['deviceId']?.toString() == deviceId,
    );
    if (!peerExists) {
      setState(() {
        file.status = SendQueueStatus.queued;
        file.errorMessage = null;
      });
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Peer is no longer available for file transfer. File moved back to queue.',
          ),
        ),
      );
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    final success = await _submitStagedFileToPeer(
      client: client,
      staged: file,
      deviceId: deviceId,
    );
    if (!mounted) return;
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
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open saved file: $error')),
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Saving ${offer['fileName'] ?? 'file'}\n'
            'Saved to: $destinationPath',
          ),
        ),
      );
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
      messenger.showSnackBar(
        SnackBar(content: Text('Rejected ${offer['fileName'] ?? 'file'}')),
      );
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
      return Text(
        'No recent clipboard items from trusted devices yet.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Column(
      children: _clipboardOffers.map((offer) {
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
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(growable: false),
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

  Widget _buildFileSendSection(ThemeData theme) {
    final peers = _fileCapablePeers;
    final queuedCount = _stagedFiles
        .where((file) => file.status != SendQueueStatus.sent)
        .length;
    final activeOutgoingTransfers = _activeOutgoingTransfers;
    return _buildSectionCard(
      theme: theme,
      title: 'Send File / Video',
      subtitle:
          'Hai bên đều có thể chủ động gửi. Mục này chỉ hiện peer đang trusted và có capability file.transfer.',
      isLoading: _isRefreshingPeers,
      onRefresh: _refreshTrustedPeers,
      child: peers.isEmpty
          ? Text(
              'No trusted peer currently advertises file.transfer.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
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
                      onPressed: _stagedFiles.any(
                        (file) => file.status == SendQueueStatus.sent,
                      )
                          ? _clearFinishedStagedFiles
                          : null,
                      child: const Text('Clear Sent'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildStagedFilesList(theme),
                const SizedBox(height: 12),
                ...peers.map((peer) {
                  final deviceId = peer['deviceId']?.toString();
                  final isSending = deviceId != null &&
                      _sendingFilePeerIds.contains(deviceId);
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
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: isSending || queuedCount == 0
                              ? null
                              : () => _sendStagedFilesToPeer(peer),
                          icon: isSending
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.upload_file),
                          label: Text(
                            isSending
                                ? 'Sending...'
                                : queuedCount == 0
                                    ? 'Queue Empty'
                                    : 'Send All ($queuedCount)',
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
      items: _stagedFiles
          .map(
            (file) => SendQueueItemData(
              fileName: file.fileName,
              mediaType: file.mediaType,
              byteSize: file.byteSize,
              bytesTransferred: file.bytesTransferred,
              status: file.status,
              errorMessage: file.errorMessage,
            ),
          )
          .toList(growable: false),
      onRemove: (index) => _removeStagedFile(_stagedFiles[index]),
      onRetry: (index) => _retryFailedStagedFile(_stagedFiles[index]),
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

class _StagedSendFile {
  _StagedSendFile({
    required this.localPath,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
  });

  final String localPath;
  final String fileName;
  final String mediaType;
  final int byteSize;
  String? transferId;
  String? operationId;
  String? targetDeviceId;
  int bytesTransferred = 0;
  String? errorMessage;
  SendQueueStatus status = SendQueueStatus.queued;
}
