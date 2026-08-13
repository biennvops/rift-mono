import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../src/file_transfer/legacy_send_queue_coordinator.dart';
import '../../src/file_transfer/send_queue_controller.dart';
import '../../src/file_transfer/send_queue_entry.dart';
import '../../src/file_transfer/send_queue_mode_coordinator.dart';
import '../../src/file_transfer/send_queue_panel.dart';
import '../../src/file_transfer/send_queue_targeting.dart';
import '../../src/ipc/json_rpc_client.dart';
import '../../src/platform/macos_send_files.dart';
import '../../widgets/rift_snackbar.dart';
import '../../widgets/premium_dialog.dart';

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

class FileSendView extends StatefulWidget {
  final String? preferredTargetDeviceId;
  final int? targetRequestVersion;
  final Future<List<Map<String, String>>> Function()? pickSendFilesOverride;
  final VoidCallback? onTargetScopeCleared;
  final VoidCallback? onViewActivityRequested;

  const FileSendView({
    super.key,
    this.preferredTargetDeviceId,
    this.targetRequestVersion,
    this.pickSendFilesOverride,
    this.onTargetScopeCleared,
    this.onViewActivityRequested,
  });

  @override
  State<FileSendView> createState() => _FileSendViewState();
}

class _FileSendViewState extends State<FileSendView> {
  static const _legacyQueueCoordinator = LegacySendQueueCoordinator();

  final List<Map<String, dynamic>> _trustedPeers = [];
  final List<Map<String, dynamic>> _fileTransfers = [];
  final Set<String> _selectedSendDeviceIds = <String>{};
  final Set<String> _legacySendingFilePeerIds = <String>{};

  bool _hasUserModifiedSendDevices = false;
  String? _preferredTargetDeviceId;

  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<Map<String, dynamic>>? _fileProgressSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;

  SendQueueController get _sendQueue => context.read<SendQueueController>();
  SendQueueModeCoordinator get _queueMode =>
      SendQueueModeCoordinator(_sendQueue, _legacyQueueCoordinator);

  @override
  void initState() {
    super.initState();
    _applyPreferredTarget();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_sendQueue.ensureRestored());
      _bindStreams();
      _refreshTrustedPeers();
      _refreshTransfers();
    });
  }

  @override
  void didUpdateWidget(FileSendView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetRequestVersion != widget.targetRequestVersion) {
      _applyPreferredTarget();
    }
  }

  void _applyPreferredTarget() {
    _preferredTargetDeviceId = widget.preferredTargetDeviceId;
    if (_preferredTargetDeviceId != null &&
        _preferredTargetDeviceId!.isNotEmpty) {
      _hasUserModifiedSendDevices = false;
      _selectedSendDeviceIds.clear();
    }
  }

  @override
  void dispose() {
    _trustChangedSub?.cancel();
    _fileProgressSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    super.dispose();
  }

  void _bindStreams() {
    final client = context.read<JsonRpcRiftClient>();
    _trustChangedSub = client.onTrustChanged.listen((_) {
      if (mounted) unawaited(_refreshTrustedPeers());
    });
    _fileProgressSub = client.onFileTransferProgress.listen((event) {
      unawaited(_handleLegacyTransferProgress(event));
      if (mounted) unawaited(_refreshTransfers());
    });
    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      unawaited(_handleLegacyTransferCompleted(event));
      if (mounted) unawaited(_refreshTransfers());
    });
    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      unawaited(_handleLegacyTransferFailed(event));
      if (mounted) unawaited(_refreshTransfers());
    });
  }

  Future<void> _refreshTrustedPeers() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listTrustedPeers();
      final peers = List<Map<String, dynamic>>.from(
        (result['peers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      if (!mounted) return;
      setState(() {
        _trustedPeers
          ..clear()
          ..addAll(peers);
      });
    } catch (_) {}
  }

  Future<void> _refreshTransfers() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listFileTransfers();
      final transfers = List<Map<String, dynamic>>.from(
        (result['transfers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      if (!mounted) return;
      setState(() {
        _fileTransfers
          ..clear()
          ..addAll(transfers);
      });
    } catch (_) {}
  }

  List<Map<String, dynamic>> get _fileCapablePeers {
    return _trustedPeers.where((peer) {
      final trustState = peer['trustState']?.toString();
      if (trustState != 'trusted') return false;

      final capabilitiesList = peer['capabilities'] as List?;
      if (capabilitiesList == null || capabilitiesList.isEmpty) return true;

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

  String _peerLabel(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return 'Unknown Device';
    }

    for (final peer in _trustedPeers) {
      if (peer['deviceId']?.toString() == deviceId) {
        final displayName = peer['displayName']?.toString();
        if (displayName != null && displayName.isNotEmpty) {
          return displayName;
        }
      }
    }

    return deviceId;
  }

  Future<void> _addFilesToSendQueue() async {
    final messenger = ScaffoldMessenger.of(context);
    final pickResult = await _pickSendFileRequests();
    final requests = pickResult.requests;
    if (!mounted) return;

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
    required String successPrefix,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await _sendQueue.enqueueRequests(requests);
    if (!mounted) return;

    if (result.isEmpty) {
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: 'No new file was added to the send queue.',
        type: RiftSnackbarType.warning,
      );
      return;
    }

    setState(() {});
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

  Future<_PickSendFilesResult> _pickSendFileRequests() async {
    if (widget.pickSendFilesOverride != null) {
      return _PickSendFilesResult(
          requests: await widget.pickSendFilesOverride!.call());
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
          skippedFileNames
              .add(picked.name.trim().isEmpty ? 'Unnamed file' : picked.name);
          continue;
        }
        requests.add({
          'localPath': resolvedPath,
          'fileName': picked.name,
          'mediaType': _guessMediaTypeFromName(picked.name),
        });
      }
      return _PickSendFilesResult(
          requests: requests, skippedFileNames: skippedFileNames);
    } catch (_) {
      final fallback = await _showSendFileFallbackDialog();
      if (fallback == null) {
        return const _PickSendFilesResult(requests: <Map<String, String>>[]);
      }
      return _PickSendFilesResult(
          requests: <Map<String, String>>[fallback], usedFallback: true);
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
    final stagingDir =
        Directory('${tempRoot.path}${Platform.pathSeparator}rift-send-staging');
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
      if (await stagedFile.exists()) return stagedPath;
    }

    final bytes = picked.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      await stagedFile.writeAsBytes(bytes, flush: true);
      return stagedPath;
    }

    return null;
  }

  Future<Map<String, String>?> _showSendFileFallbackDialog() async {
    final pathController = TextEditingController();
    final nameController = TextEditingController();
    final typeController =
        TextEditingController(text: 'application/octet-stream');
    String? validationError;

    return showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final path = pathController.text.trim();
              final name = nameController.text.trim();
              final type = typeController.text.trim();
              if (path.isEmpty) {
                setDialogState(
                    () => validationError = 'Enter a local file path.');
                return;
              }
              if (!File(path).existsSync()) {
                setDialogState(
                    () => validationError = 'That file path does not exist.');
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
                      hint: '/path/to/file',
                      autofocus: true),
                  const SizedBox(height: 12),
                  PremiumTextField(
                      controller: nameController,
                      label: 'Display file name (optional)'),
                  const SizedBox(height: 12),
                  PremiumTextField(
                      controller: typeController, label: 'Media type'),
                  if (validationError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      validationError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
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
  }

  void _toggleSendDevice(String deviceId, Set<String> effectiveSelectedIds) {
    setState(() {
      if (!_hasUserModifiedSendDevices) {
        _hasUserModifiedSendDevices = true;
        _selectedSendDeviceIds.clear();
        _selectedSendDeviceIds.addAll(effectiveSelectedIds);
        widget.onTargetScopeCleared?.call();
      }
      if (_selectedSendDeviceIds.contains(deviceId)) {
        _selectedSendDeviceIds.remove(deviceId);
      } else {
        _selectedSendDeviceIds.add(deviceId);
      }
    });
  }

  Set<String> _effectiveSelectedIds(List<Map<String, dynamic>> peers) {
    if (_selectedSendDeviceIds.isNotEmpty || _hasUserModifiedSendDevices) {
      return _selectedSendDeviceIds.intersection(
        peers.map((p) => p['deviceId']?.toString() ?? '').toSet(),
      );
    }
    final preferred = _preferredTargetDeviceId;
    if (preferred != null &&
        peers.any((peer) => peer['deviceId']?.toString() == preferred)) {
      return <String>{preferred};
    }
    return peers.isNotEmpty
        ? <String>{peers.first['deviceId']?.toString() ?? ''}
        : <String>{};
  }

  Future<void> _sendStagedFilesToSelectedPeers() async {
    final peers = _fileCapablePeers;
    if (peers.isEmpty) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message:
            'No trusted peer currently advertises file.transfer capability.',
        type: RiftSnackbarType.warning,
      );
      return;
    }
    final effectiveSelectedIds = _effectiveSelectedIds(peers);

    if (effectiveSelectedIds.isEmpty) return;

    for (final deviceId in effectiveSelectedIds) {
      final peer = peers.firstWhere(
          (p) => p['deviceId']?.toString() == deviceId,
          orElse: () => <String, dynamic>{});
      if (peer.isNotEmpty) {
        await _sendStagedFilesToPeer(peer);
      }
    }
  }

  Future<void> _sendStagedFilesToPeer(Map<String, dynamic> peer) async {
    final deviceId = peer['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;

    final isLegacyMode = await _queueMode.isLegacyLocalQueueMode();
    if (!mounted) return;

    final client = context.read<JsonRpcRiftClient>();
    final queuedFiles = _eligibleFilesForPeer(deviceId);

    if (queuedFiles.isEmpty) {
      RiftSnackbar.show(
        context: context,
        message: 'No queued file is ready to send to $deviceId.',
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
          if (mounted) setState(mutation);
        },
        persistQueue: _sendQueue.persist,
        onLegacySubmitted: (staged) {
          if (mounted) {
            setState(() {
              staged.autoRetryWhenPeerAvailable = false;
            });
          }
        },
      );
      if (!mounted) return;
      if (submitted == 0) {
        RiftSnackbar.showWithState(
          messenger: messenger,
          message: 'No file was submitted to $deviceId.',
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

  List<SendQueueEntry> _eligibleFilesForPeer(String deviceId) {
    return _sendQueue.items.where((file) {
      return SendQueueTargeting.isEligibleForPeer(
        status: file.status,
        targetDeviceId: file.targetDeviceId,
        peerDeviceId: deviceId,
      );
    }).toList(growable: false);
  }

  Future<void> _cancelStagedFile(SendQueueEntry file) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _sendQueue.cancelItem(file);
      if (!mounted) return;
      setState(() {});
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: file.status == SendQueueStatus.sending
            ? 'Cancelled ${file.fileName}.'
            : 'Removed ${file.fileName} from the queue.',
        type: RiftSnackbarType.info,
      );
    } catch (error) {
      if (!mounted) return;
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: JsonRpcRiftClient.formatDisplayError(error),
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _clearFinishedStagedFiles() async {
    final sentItems = _sendQueue.items
        .where((item) => item.status == SendQueueStatus.sent)
        .toList();
    for (final item in sentItems) {
      await _sendQueue.removeItem(item);
    }
    if (mounted) setState(() {});
  }

  Future<void> _retryFailedStagedFile(SendQueueEntry file) async {
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<JsonRpcRiftClient>();
    final deviceId = file.targetDeviceId;
    var handledByCallback = false;
    final peerExists = deviceId != null &&
        deviceId.isNotEmpty &&
        _fileCapablePeers
            .any((candidate) => candidate['deviceId']?.toString() == deviceId);

    final success = await _queueMode.retryFailedItem(
      client: client,
      file: file,
      peerExists: peerExists,
      isMounted: () => mounted,
      mutateUi: (mutation) {
        if (mounted) setState(mutation);
      },
      persistQueue: _sendQueue.persist,
      onNeedsPeerSelection: () {
        if (mounted) {
          setState(() {});
          RiftSnackbar.showWithState(
            messenger: messenger,
            message:
                'File moved back to queue. Choose a peer to send it again.',
            type: RiftSnackbarType.info,
          );
        }
      },
      onPeerUnavailable: (peerDeviceId) {
        handledByCallback = true;
        if (mounted) {
          setState(() {
            file.status = SendQueueStatus.failed;
            file.errorMessage =
                'Target device $peerDeviceId is no longer available for file transfer.';
            file.autoRetryWhenPeerAvailable = false;
            file.transferId = null;
            file.operationId = null;
            file.bytesTransferred = 0;
          });
          unawaited(_sendQueue.persist());
          RiftSnackbar.showWithState(
            messenger: messenger,
            message: '$peerDeviceId is no longer available for file transfer.',
            type: RiftSnackbarType.error,
          );
        }
      },
      onLegacySubmitted: (staged) {
        if (mounted) {
          setState(() {
            staged.autoRetryWhenPeerAvailable = false;
          });
        }
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

  Future<void> _chooseDeviceForStagedFile(SendQueueEntry file) async {
    final messenger = ScaffoldMessenger.of(context);
    final peers = _fileCapablePeers;
    final targetDeviceId =
        peers.isNotEmpty ? peers.first['deviceId']?.toString() : null;
    try {
      if (targetDeviceId != null) {
        await _sendQueue.assignTarget(file, targetDeviceId: targetDeviceId);
      } else {
        await _sendQueue.retargetForSelection(file);
      }
      if (!mounted) return;
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      RiftSnackbar.showWithState(
        messenger: messenger,
        message: JsonRpcRiftClient.formatDisplayError(error),
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _handleLegacyTransferProgress(Map<String, dynamic> event) async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    final transferId = event['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) return;
    final staged = _findStagedFileByTransferId(transferId);
    if (staged == null || !mounted) return;

    setState(() {
      staged.bytesTransferred = (event['bytesTransferred'] as num?)?.toInt() ??
          staged.bytesTransferred;
      staged.status = SendQueueStatus.sending;
    });
    unawaited(_sendQueue.persist());
  }

  Future<void> _handleLegacyTransferCompleted(
      Map<String, dynamic> event) async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    final transferId = event['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) return;
    final staged = _findStagedFileByTransferId(transferId);
    if (staged == null || !mounted) return;

    setState(() {
      staged.bytesTransferred = staged.byteSize;
      staged.status = SendQueueStatus.sent;
      staged.errorMessage = null;
      staged.autoRetryWhenPeerAvailable = false;
    });
    unawaited(_sendQueue.persist());
  }

  Future<void> _handleLegacyTransferFailed(Map<String, dynamic> event) async {
    if (!await _queueMode.isLegacyLocalQueueMode()) {
      return;
    }
    final transferId = event['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) return;
    final staged = _findStagedFileByTransferId(transferId);
    if (staged == null || !mounted) return;

    final rawMessage =
        event['message']?.toString() ?? event['failureReason']?.toString();
    setState(() {
      staged.status = SendQueueStatus.failed;
      staged.errorMessage = rawMessage;
    });
    unawaited(_sendQueue.persist());
  }

  SendQueueEntry? _findStagedFileByTransferId(String transferId) {
    for (final staged in _sendQueue.items) {
      if (staged.transferId == transferId) return staged;
    }
    return null;
  }

  String _guessMediaTypeFromName(String fileName) {
    final normalized = fileName.toLowerCase();
    if (normalized.endsWith('.pdf')) return 'application/pdf';
    if (normalized.endsWith('.jpg') || normalized.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (normalized.endsWith('.png')) return 'image/png';
    if (normalized.endsWith('.mp4')) return 'video/mp4';
    if (normalized.endsWith('.txt')) return 'text/plain';
    if (normalized.endsWith('.zip')) return 'application/zip';
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

  String _fileExtension(String fileName) {
    final idx = fileName.lastIndexOf('.');
    return idx != -1 && idx < fileName.length - 1
        ? fileName.substring(idx + 1).toUpperCase()
        : 'FILE';
  }

  IconData _mediaTypeIcon(String? mediaType) {
    final normalized = mediaType?.toLowerCase() ?? '';
    if (normalized.startsWith('video/')) return Icons.movie;
    if (normalized.startsWith('image/')) return Icons.image;
    if (normalized.startsWith('audio/')) return Icons.audiotrack;
    if (normalized == 'application/pdf') return Icons.picture_as_pdf;
    if (normalized.contains('zip') || normalized.contains('tar')) {
      return Icons.archive;
    }
    if (normalized.startsWith('text/')) return Icons.description;
    return Icons.insert_drive_file;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SendQueueController>();
    final theme = Theme.of(context);
    final peers = _fileCapablePeers;
    final queueItems = _sendQueue.items;
    final hasSendableFiles = queueItems.any((f) =>
        f.status == SendQueueStatus.queued ||
        f.status == SendQueueStatus.failed);

    final effectiveSelectedIds = _effectiveSelectedIds(peers);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (_activeOutgoingTransfers.isNotEmpty) ...[
          _buildOutgoingTransferBanner(
            theme,
            _activeOutgoingTransfers,
          ),
          const SizedBox(height: 10),
        ],
        _buildSendControlsCard(
          theme,
          peers: peers,
          effectiveSelectedIds: effectiveSelectedIds,
          hasSendableFiles: hasSendableFiles,
        ),
        const SizedBox(height: 10),
        _buildTransferHubQueueCard(theme, queueItems),
      ],
    );
  }

  Widget _buildSendControlsCard(
    ThemeData theme, {
    required List<Map<String, dynamic>> peers,
    required Set<String> effectiveSelectedIds,
    required bool hasSendableFiles,
  }) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Files'),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                if (!isMobile)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Or drag files here',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'SEND TO',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 8),
            if (peers.isEmpty)
              Text(
                'No available peers.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = constraints.maxWidth < 600
                      ? (constraints.maxWidth - 8) / 2
                      : null;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: peers.map((peer) {
                      final deviceId = peer['deviceId']?.toString() ?? '';
                      final isSelected =
                          effectiveSelectedIds.contains(deviceId);
                      return _buildDeviceSelectChip(
                        theme,
                        deviceId: deviceId,
                        label: _peerLabel(deviceId),
                        platform: peer['platform']?.toString(),
                        isSelected: isSelected,
                        isOnline: peer['presence']?.toString() == 'online',
                        width: itemWidth,
                        onTap: () =>
                            _toggleSendDevice(deviceId, effectiveSelectedIds),
                      );
                    }).toList(),
                  );
                },
              ),
            if (_sendQueue.items.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 8,
                children: [
                  Text(
                    '${_sendQueue.items.length} file(s) ready',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed:
                        hasSendableFiles && effectiveSelectedIds.isNotEmpty
                            ? _sendStagedFilesToSelectedPeers
                            : null,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    label: Text(
                      effectiveSelectedIds.isEmpty
                          ? 'Select a device'
                          : 'Send to ${effectiveSelectedIds.length} device'
                              '${effectiveSelectedIds.length == 1 ? '' : 's'}',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      disabledBackgroundColor:
                          theme.colorScheme.surfaceContainerHigh,
                      disabledForegroundColor: theme.colorScheme.outline,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceSelectChip(
    ThemeData theme, {
    required String label,
    required String deviceId,
    required String? platform,
    required bool isSelected,
    required bool isOnline,
    required double? width,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        key: ValueKey('send-device-chip-$deviceId'),
        width: width,
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.08)
              : Colors.white,
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
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline
                    ? const Color(0xFF22C55E)
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              _platformIcon(platform),
              size: 18,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: isSelected ? theme.colorScheme.primary : Colors.white,
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

  IconData _platformIcon(String? platform) {
    return switch (platform?.toLowerCase()) {
      'android' || 'ios' => Icons.smartphone,
      'windows' => Icons.desktop_windows,
      'macos' || 'mac' || 'osx' => Icons.laptop_mac,
      'linux' => Icons.computer,
      _ => Icons.devices,
    };
  }

  Widget _buildTransferHubQueueCard(
      ThemeData theme, List<SendQueueEntry> queueItems) {
    final activeItems =
        queueItems.where((e) => e.status != SendQueueStatus.sent).toList();
    final sentItems =
        queueItems.where((e) => e.status == SendQueueStatus.sent).toList();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Send Queue · ${activeItems.length} ITEM(S)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (sentItems.isNotEmpty)
                  TextButton.icon(
                    onPressed: _clearFinishedStagedFiles,
                    icon: const Icon(Icons.cleaning_services, size: 16),
                    label: const Text('Clear Sent'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_fileCapablePeers.isEmpty && activeItems.isNotEmpty) ...[
                  Text(
                    'No trusted peer currently advertises file.transfer.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (activeItems.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Text(
                        'Queue Empty',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: activeItems.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox.shrink(),
                    itemBuilder: (context, index) =>
                        _buildTransferQueueFileTile(theme, activeItems[index]),
                  ),
                if (sentItems.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Completed Transfers',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: sentItems.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox.shrink(),
                    itemBuilder: (context, index) =>
                        _buildTransferQueueFileTile(theme, sentItems[index]),
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
    final canRetarget = file.status == SendQueueStatus.failed &&
        (file.errorMessage?.toLowerCase().contains('no longer available') ??
            false);

    final targetText =
        file.targetDeviceId == null || file.targetDeviceId!.isEmpty
            ? null
            : 'Target: ${_peerLabel(file.targetDeviceId)}';
    final metaText =
        '${_formatSize(file.byteSize)} · ${_fileExtension(file.fileName)}'
        '${targetText != null ? ' · $targetText' : ''}'
        '${file.errorMessage != null && file.errorMessage!.trim().isNotEmpty ? ' · ${file.errorMessage}' : ''}';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color:
                    theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Icon(_mediaTypeIcon(file.mediaType),
                size: 20, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.fileName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  metaText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: file.status == SendQueueStatus.failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (file.status == SendQueueStatus.sending) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: theme.colorScheme.surfaceContainer,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.primary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          _buildQueueStatusCapsule(theme, file.status),
          const SizedBox(width: 16),
          Wrap(
            spacing: 8,
            children: [
              if (file.targetDeviceId == null ||
                  file.targetDeviceId!.isEmpty) ...[
                OutlinedButton(
                  onPressed: () => _chooseDeviceForStagedFile(file),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.primary),
                    foregroundColor: theme.colorScheme.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  child: Text(
                    () {
                      final unassignedCount = _sendQueue.items
                          .where((item) =>
                              item.targetDeviceId == null ||
                              item.targetDeviceId!.isEmpty)
                          .length;
                      return unassignedCount > 0
                          ? 'Send Unassigned ($unassignedCount)'
                          : 'Send Unassigned';
                    }(),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              if (canRetry)
                OutlinedButton(
                  onPressed: () => _retryFailedStagedFile(file),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.primary),
                    foregroundColor: theme.colorScheme.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text('Retry',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              if (canRetarget && !canRetry)
                OutlinedButton(
                  onPressed: () => _chooseDeviceForStagedFile(file),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.primary),
                    foregroundColor: theme.colorScheme.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text('Retarget',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              OutlinedButton.icon(
                onPressed: () => _cancelStagedFile(file),
                icon: Icon(
                    file.status == SendQueueStatus.sending
                        ? Icons.stop_circle_outlined
                        : Icons.close,
                    size: 16),
                label: Text(
                  file.status == SendQueueStatus.sending ? 'Cancel' : 'Remove',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  minimumSize: const Size(0, 32),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQueueStatusCapsule(ThemeData theme, SendQueueStatus status) {
    Color bg;
    Color fg;
    String label;
    switch (status) {
      case SendQueueStatus.queued:
        bg = theme.colorScheme.surfaceContainerHigh;
        fg = theme.colorScheme.onSurfaceVariant;
        label = 'READY';
        break;
      case SendQueueStatus.sending:
        bg = theme.colorScheme.primaryContainer.withValues(alpha: 0.2);
        fg = theme.colorScheme.primary;
        label = 'SENDING';
        break;
      case SendQueueStatus.sent:
        bg = const Color(0xFF12744F).withValues(alpha: 0.15);
        fg = const Color(0xFF12744F);
        label = 'SENT';
        break;
      case SendQueueStatus.failed:
        bg = theme.colorScheme.errorContainer;
        fg = theme.colorScheme.error;
        label = 'FAILED';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: fg,
            letterSpacing: 0.5),
      ),
    );
  }

  Widget _buildOutgoingTransferBanner(
    ThemeData theme,
    List<Map<String, dynamic>> activeTransfers,
  ) {
    final count = activeTransfers.length;
    final primaryPeer =
        activeTransfers.first['peerDeviceId']?.toString() ?? 'Device';
    final summary = count > 1
        ? 'Now sending $count file(s)...'
        : 'Now sending 1 file(s) to ${_peerLabel(primaryPeer)}...';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.sync,
              size: 20, color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: widget.onViewActivityRequested,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              side: BorderSide(
                color: theme.colorScheme.onPrimaryContainer.withValues(
                  alpha: 0.35,
                ),
              ),
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text('View Activity'),
          ),
        ],
      ),
    );
  }
}
