import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ipc/json_rpc_client.dart';
import '../platform/notification_route.dart';
import '../../constants.dart';
import '../ui/app_shell.dart';
import '../platform/android_shell.dart';
import '../platform/windows_shell.dart';
import '../platform/macos_send_files.dart';
import '../../widgets/premium_dialog.dart';
import '../../widgets/rift_snackbar.dart';
import 'send_queue_controller.dart';
import 'file_storage.dart';

class FileTransferCoordinator {
  final JsonRpcRiftClient client;
  final GlobalKey<NavigatorState> navigatorKey;
  final GlobalKey<AppShellState> appShellKey;
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;
  final void Function(String title, String body) onNotify;
  final void Function({
    required String title,
    required String body,
    String? route,
    Map<String, Object?>? payload,
    String? destinationPath,
  }) onNotifyWithRoute;
  final Future<String?> Function(
    String fileName,
    Set<String> reservedPaths,
  )? buildIncomingFilePathOverride;

  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;

  final Set<String> _autoAcceptingTransferIds = <String>{};
  final Set<String> _reservedIncomingPaths = <String>{};
  final Map<String, Map<String, dynamic>> _pendingIncomingOffers = {};
  Timer? _incomingOfferBatchTimer;
  bool _isHandlingIncomingBatch = false;

  final List<Map<String, String>> _pendingSharedSendItems =
      <Map<String, String>>[];

  FileTransferCoordinator({
    required this.client,
    required this.navigatorKey,
    required this.appShellKey,
    required this.scaffoldMessengerKey,
    required this.onNotify,
    required this.onNotifyWithRoute,
    this.buildIncomingFilePathOverride,
  });

  void init() {
    _bindIpcEvents();
    if (Platform.isMacOS) {
      MacOSSendFiles.setMethodCallHandler(_handleMacOSSendFilesMethodCall);
    }
  }

  void dispose() {
    _incomingOfferBatchTimer?.cancel();
    _fileOfferSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
  }

  void _bindIpcEvents() {
    _fileOfferSub = client.onFileOffer.listen((event) {
      _queueIncomingFileOffer(event);
    });

    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final peer = event['peerDeviceId']?.toString() ?? 'trusted device';
      final destinationPath = event['destinationPath']?.toString();
      final isIncoming =
          destinationPath != null && destinationPath.trim().isNotEmpty;
      onNotify(
        isIncoming ? 'File received' : 'File sent',
        destinationPath == null || destinationPath.trim().isEmpty
            ? '$fileName ${isIncoming ? 'received from' : 'sent to'} $peer.'
            : '$fileName saved to $destinationPath.',
      );
      _maybeNotifyCompletedTransfer(
        title: isIncoming ? 'File received' : 'File sent',
        body: destinationPath == null || destinationPath.trim().isEmpty
            ? '$fileName ${isIncoming ? 'received from' : 'sent to'} $peer.'
            : '$fileName saved to $destinationPath.',
        destinationPath: destinationPath,
      );
    });

    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final reason = event['failureReason']?.toString() ?? 'failed';
      onNotifyWithRoute(
        title: 'File transfer failed',
        body: '$fileName failed: $reason.',
        route: NotificationRoute.historyTransferActivity,
      );
    });
  }

  Future<dynamic> _handleMacOSSendFilesMethodCall(MethodCall call) async {
    if (call.method != MacOSSendFiles.callbackMethod) {
      return null;
    }

    final items = MacOSSendFiles.parseCallbackArguments(call.arguments);
    if (items.isEmpty) {
      return null;
    }

    unawaited(_enqueueSharedSendItems(items));
    appShellKey.currentState?.showHistoryRoute(NotificationRoute.historySend);
    return null;
  }

  Future<void> _enqueueSharedSendItems(List<Map<String, String>> items) async {
    if (items.isEmpty) return;
    _pendingSharedSendItems.addAll(items);
    await flushPendingSharedSendItems();
  }

  Future<void> flushPendingSharedSendItems() async {
    if (_pendingSharedSendItems.isEmpty) {
      return;
    }
    final pending = List<Map<String, String>>.from(_pendingSharedSendItems);
    _pendingSharedSendItems.clear();

    if (!client.isConnected) {
      _pendingSharedSendItems.insertAll(0, pending);
      return;
    }

    final context = navigatorKey.currentContext;
    if (context == null) {
      _pendingSharedSendItems.insertAll(0, pending);
      return;
    }

    final result = await context.read<SendQueueController>().enqueueRequests(
          pending,
        );
    debugPrint(
      '[Send Queue] Drained buffered shared items: added=${result.added} skipped=${result.skipped}',
    );

    if (result.skipped > 0 &&
        !_pendingSharedSendItems.contains(pending.first)) {
      debugPrint(
        '[Send Queue] ${result.skipped} shared item(s) still could not be enqueued after reconnect.',
      );
    }
  }

  void _maybeNotifyCompletedTransfer({
    required String title,
    required String body,
    String? destinationPath,
  }) {
    unawaited(() async {
      try {
        if (Platform.isWindows &&
            destinationPath != null &&
            destinationPath.trim().isNotEmpty) {
          await WindowsShell.showTransferNotification(
            title: title,
            body: body,
            destinationPath: destinationPath,
          );
          return;
        }
        if (Platform.isAndroid &&
            destinationPath != null &&
            destinationPath.trim().isNotEmpty) {
          await AndroidShell.showNotification(
            title: title,
            body: body,
            route: NotificationRoute.historyTransferActivity,
            destinationPath: destinationPath,
            payload: const <String, Object?>{'openDestination': true},
          );
          return;
        }
        onNotifyWithRoute(
          title: title,
          body: body,
          route: NotificationRoute.historyTransferActivity,
          destinationPath: destinationPath,
        );
      } catch (_) {
        // Best-effort.
      }
    }());
  }

  Future<bool?> _confirmIncomingFileBatch({
    required List<
            ({
              String transferId,
              String fileName,
              String sourceDeviceId,
              String destinationPath,
            })>
        offers,
  }) async {
    final context = navigatorKey.currentContext;
    if (context == null) {
      return true;
    }

    final sourceDeviceIds = offers.map((offer) => offer.sourceDeviceId).toSet();
    final singleSource =
        sourceDeviceIds.length == 1 ? sourceDeviceIds.single : null;
    final fileLabel =
        offers.length == 1 ? offers.single.fileName : '${offers.length} files';
    final sourceLabel =
        singleSource ?? '${sourceDeviceIds.length} trusted devices';
    final destinationLabel = offers.length == 1
        ? offers.single.destinationPath
        : File(offers.first.destinationPath).parent.path;

    bool autoAccept = false;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          return PremiumDialog(
            title: offers.length == 1
                ? 'Incoming File'
                : '${offers.length} Incoming Files',
            subtitle: offers.length == 1
                ? 'A trusted peer wants to send you a file.'
                : 'Review and accept all files together.',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // File Name
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.insert_drive_file,
                        size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'File',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            fileLabel,
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Sender
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.person,
                        size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'From',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            sourceLabel,
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Destination
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.folder,
                        size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Save to',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            destinationLabel,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (singleSource != null)
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        autoAccept = !autoAccept;
                      });
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: autoAccept,
                            onChanged: (val) {
                              setState(() {
                                autoAccept = val == true;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Always auto-accept files from this device',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            cancelText: 'Decline',
            confirmText: 'Accept',
            onCancel: () => Navigator.of(dialogContext).pop(false),
            onConfirm: () async {
              if (autoAccept && singleSource != null) {
                final prefs = await SharedPreferences.getInstance();
                final list =
                    prefs.getStringList(AppPrefs.autoAcceptDeviceIds) ??
                        <String>[];
                if (!list.contains(singleSource)) {
                  list.add(singleSource);
                  await prefs.setStringList(AppPrefs.autoAcceptDeviceIds, list);
                }
              }
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop(true);
              }
            },
          );
        },
      ),
    );
  }

  void _queueIncomingFileOffer(Map<String, dynamic> event) {
    final transferId = event['transferId']?.toString();
    final fileName = event['fileName']?.toString();
    if (transferId == null ||
        transferId.isEmpty ||
        fileName == null ||
        fileName.isEmpty) {
      return;
    }
    if (_autoAcceptingTransferIds.contains(transferId)) {
      return;
    }

    _pendingIncomingOffers[transferId] = event;
    _incomingOfferBatchTimer?.cancel();
    _incomingOfferBatchTimer = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(_processIncomingOfferBatch()),
    );
  }

  Future<void> _processIncomingOfferBatch() async {
    if (_isHandlingIncomingBatch || _pendingIncomingOffers.isEmpty) {
      return;
    }
    _isHandlingIncomingBatch = true;
    final events = _pendingIncomingOffers.values.toList(growable: false);
    _pendingIncomingOffers.clear();
    final prepared = <({
      String transferId,
      String fileName,
      String sourceDeviceId,
      String destinationPath,
    })>[];

    try {
      for (final event in events) {
        final transferId = event['transferId']?.toString() ?? '';
        final fileName = event['fileName']?.toString() ?? '';
        final sourceDeviceId =
            event['sourceDeviceId']?.toString() ?? 'trusted device';
        if (transferId.isEmpty || fileName.isEmpty) continue;

        final destinationPath = buildIncomingFilePathOverride != null
            ? await buildIncomingFilePathOverride!(
                fileName,
                _reservedIncomingPaths,
              )
            : await buildDefaultIncomingFilePath(
                fileName,
                reservedPaths: _reservedIncomingPaths,
              );
        if (destinationPath == null || destinationPath.isEmpty) {
          await _rejectUnavailableOffer(transferId, fileName);
          continue;
        }
        _reservedIncomingPaths.add(destinationPath);
        _autoAcceptingTransferIds.add(transferId);
        prepared.add((
          transferId: transferId,
          fileName: fileName,
          sourceDeviceId: sourceDeviceId,
          destinationPath: destinationPath,
        ));
      }

      if (prepared.isEmpty) return;

      final sourceCount =
          prepared.map((offer) => offer.sourceDeviceId).toSet().length;
      onNotifyWithRoute(
        title: prepared.length == 1
            ? 'Incoming file'
            : '${prepared.length} incoming files',
        body: sourceCount == 1
            ? 'From ${prepared.first.sourceDeviceId}.'
            : 'From $sourceCount trusted devices.',
        route: NotificationRoute.historyIncomingOffers,
      );

      final prefs = await SharedPreferences.getInstance();
      final autoAcceptDevices =
          prefs.getStringList(AppPrefs.autoAcceptDeviceIds) ?? <String>[];
      final shouldAccept = prepared.every(
            (offer) => autoAcceptDevices.contains(offer.sourceDeviceId),
          ) ||
          (await _confirmIncomingFileBatch(offers: prepared) ?? false);

      if (!shouldAccept) {
        for (final offer in prepared) {
          await client.rejectFileOffer(
            transferId: offer.transferId,
            failureReason: 'PolicyDenied',
            message: 'User declined incoming file transfer.',
          );
        }
        final messenger = scaffoldMessengerKey.currentState;
        if (messenger != null) {
          RiftSnackbar.showWithState(
            messenger: messenger,
            message: 'Declined ${prepared.length} incoming file(s).',
            type: RiftSnackbarType.info,
          );
        }
        return;
      }

      var accepted = 0;
      for (final offer in prepared) {
        try {
          await client.acceptFileOffer(
            transferId: offer.transferId,
            destinationPath: offer.destinationPath,
            overwrite: false,
          );
          accepted += 1;
        } catch (error) {
          onNotifyWithRoute(
            title: 'Incoming file failed',
            body: 'Could not receive ${offer.fileName}: $error',
            route: NotificationRoute.historyTransferActivity,
          );
        }
      }

      final messenger = scaffoldMessengerKey.currentState;
      if (messenger != null && accepted > 0) {
        final destinationFolder =
            File(prepared.first.destinationPath).parent.path;
        RiftSnackbar.showWithState(
          messenger: messenger,
          message:
              'Receiving $accepted file(s). They will appear in $destinationFolder when complete.',
          type: RiftSnackbarType.info,
        );
      }
      onNotifyWithRoute(
        title: prepared.length == 1
            ? 'Incoming file'
            : '${prepared.length} incoming files',
        body: 'Receiving $accepted of ${prepared.length} file(s).',
        route: NotificationRoute.historyTransferActivity,
      );
    } finally {
      for (final offer in prepared) {
        _autoAcceptingTransferIds.remove(offer.transferId);
      }
      _isHandlingIncomingBatch = false;
      if (_pendingIncomingOffers.isNotEmpty) {
        _incomingOfferBatchTimer?.cancel();
        _incomingOfferBatchTimer = Timer(
          const Duration(milliseconds: 800),
          () => unawaited(_processIncomingOfferBatch()),
        );
      }
    }
  }

  Future<void> _rejectUnavailableOffer(
      String transferId, String fileName) async {
    try {
      try {
        await client.rejectFileOffer(
          transferId: transferId,
          failureReason: 'PolicyDenied',
          message: 'No download destination is available.',
        );
      } catch (_) {
        // Best-effort rejection.
      }
      onNotifyWithRoute(
        title: 'Incoming file failed',
        body: 'No download destination is available for $fileName.',
        route: NotificationRoute.historyTransferActivity,
      );
    } on FileSystemException {
      // Destination resolution already failed; the notification above is enough.
    }
  }
}
