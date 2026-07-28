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

  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;

  final Set<String> _autoAcceptingTransferIds = <String>{};
  final Set<String> _reservedIncomingPaths = <String>{};
  bool _isResolvingPath = false;

  final List<Map<String, String>> _pendingSharedSendItems =
      <Map<String, String>>[];

  FileTransferCoordinator({
    required this.client,
    required this.navigatorKey,
    required this.appShellKey,
    required this.scaffoldMessengerKey,
    required this.onNotify,
    required this.onNotifyWithRoute,
  });

  void init() {
    _bindIpcEvents();
    if (Platform.isMacOS) {
      MacOSSendFiles.setMethodCallHandler(_handleMacOSSendFilesMethodCall);
    }
  }

  void dispose() {
    _fileOfferSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
  }

  void _bindIpcEvents() {
    _fileOfferSub = client.onFileOffer.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final sourceDeviceId =
          event['sourceDeviceId']?.toString() ?? 'trusted device';
      onNotifyWithRoute(
        title: 'Incoming file',
        body: '$fileName from $sourceDeviceId.',
        route: NotificationRoute.historyIncomingOffers,
      );
      unawaited(_handleIncomingFileOffer(event));
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

  Future<bool?> _confirmIncomingFileOffer({
    required String fileName,
    required String sourceDeviceId,
    required String destinationPath,
  }) async {
    final context = navigatorKey.currentContext;
    if (context == null) {
      return true;
    }

    bool autoAccept = false;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          return PremiumDialog(
            title: 'Incoming File',
            subtitle: 'A trusted peer wants to send you a file.',
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
                            fileName,
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
                            sourceDeviceId,
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
                            destinationPath,
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
              if (autoAccept) {
                final prefs = await SharedPreferences.getInstance();
                final list =
                    prefs.getStringList(AppPrefs.autoAcceptDeviceIds) ??
                        <String>[];
                if (!list.contains(sourceDeviceId)) {
                  list.add(sourceDeviceId);
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

  Future<void> _handleIncomingFileOffer(Map<String, dynamic> event) async {
    final transferId = event['transferId']?.toString();
    final fileName = event['fileName']?.toString();
    final sourceDeviceId =
        event['sourceDeviceId']?.toString() ?? 'trusted device';
    if (transferId == null ||
        transferId.isEmpty ||
        fileName == null ||
        fileName.isEmpty) {
      return;
    }
    if (_autoAcceptingTransferIds.contains(transferId)) {
      return;
    }

    _autoAcceptingTransferIds.add(transferId);
    String? destinationPath;
    try {
      while (_isResolvingPath) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      _isResolvingPath = true;
      try {
        destinationPath = await buildDefaultIncomingFilePath(
          fileName,
          reservedPaths: _reservedIncomingPaths,
        );
        if (destinationPath != null && destinationPath.isNotEmpty) {
          _reservedIncomingPaths.add(destinationPath);
        }
      } finally {
        _isResolvingPath = false;
      }

      if (destinationPath == null || destinationPath.isEmpty) {
        throw const FileSystemException(
          'Could not resolve a public Downloads/Rift save location.',
        );
      }

      bool shouldAccept = false;
      final prefs = await SharedPreferences.getInstance();
      final autoAcceptDevices =
          prefs.getStringList(AppPrefs.autoAcceptDeviceIds) ?? <String>[];

      if (autoAcceptDevices.contains(sourceDeviceId)) {
        shouldAccept = true;
      } else {
        shouldAccept = await _confirmIncomingFileOffer(
              fileName: fileName,
              sourceDeviceId: sourceDeviceId,
              destinationPath: destinationPath,
            ) ??
            false;
      }

      if (!shouldAccept) {
        await client.rejectFileOffer(
          transferId: transferId,
          failureReason: 'PolicyDenied',
          message: 'User declined incoming file transfer.',
        );
        final messenger = scaffoldMessengerKey.currentState;
        if (messenger != null) {
          RiftSnackbar.showWithState(
            messenger: messenger,
            message: 'Declined $fileName from $sourceDeviceId',
            type: RiftSnackbarType.info,
          );
        }
        return;
      }

      final messenger = scaffoldMessengerKey.currentState;
      if (messenger != null) {
        RiftSnackbar.showWithState(
          messenger: messenger,
          message:
              'Receiving $fileName from $sourceDeviceId...\nSaved to: $destinationPath',
          type: RiftSnackbarType.info,
        );
      }
      onNotify('Incoming file', 'Receiving $fileName from $sourceDeviceId.');

      await client.acceptFileOffer(
        transferId: transferId,
        destinationPath: destinationPath,
        overwrite: false,
      );
    } catch (error) {
      try {
        await client.rejectFileOffer(
          transferId: transferId,
          failureReason: 'PolicyDenied',
          message: 'Incoming file transfer could not be confirmed.',
        );
      } catch (_) {
        // Best-effort reject if incoming transfer setup fails.
      }
      onNotifyWithRoute(
        title: 'Incoming file failed',
        body: 'Could not auto-save $fileName: $error',
        route: NotificationRoute.historyTransferActivity,
      );
    } finally {
      _autoAcceptingTransferIds.remove(transferId);
    }
  }
}
