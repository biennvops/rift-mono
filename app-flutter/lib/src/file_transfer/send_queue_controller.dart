import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:rift/constants.dart';
import 'package:rift/src/file_transfer/send_queue_entry.dart';
import 'package:rift/src/file_transfer/send_queue_panel.dart';
import 'package:rift/src/file_transfer/send_queue_summary.dart';
import 'package:rift/src/file_transfer/send_queue_targeting.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SendQueueController extends ChangeNotifier {
  SendQueueController([this._client, bool? preferDaemonOnlyOverride])
      : _preferDaemonOnly =
            preferDaemonOnlyOverride ?? _defaultPreferDaemonOnly() {
    final client = _client;
    if (client != null) {
      _sendQueueChangedSub = client.onSendQueueChanged.listen((_) {
        if (_hasRestored) {
          unawaited(refreshFromDaemonIfSupported());
        }
      });
      _sendQueueItemUpdatedSub = client.onSendQueueItemUpdated.listen((_) {
        if (_hasRestored) {
          unawaited(refreshFromDaemonIfSupported());
        }
      });
      _connectionChangedSub = client.onConnectionChanged.listen((isConnected) {
        if (_hasRestored && isConnected) {
          unawaited(refreshFromDaemonIfSupported());
        }
      });
    }
  }

  final List<SendQueueEntry> _items = <SendQueueEntry>[];
  bool _hasRestored = false;
  Future<void>? _restoreFuture;
  final JsonRpcRiftClient? _client;
  final bool _preferDaemonOnly;
  StreamSubscription<Map<String, dynamic>>? _sendQueueChangedSub;
  StreamSubscription<Map<String, dynamic>>? _sendQueueItemUpdatedSub;
  StreamSubscription<bool>? _connectionChangedSub;

  List<SendQueueEntry> get items => _items;

  Future<void> ensureRestored() => restore();

  static bool _defaultPreferDaemonOnly() {
    if (kIsWeb) {
      return false;
    }
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool get _shouldSkipLegacyPersistence => _preferDaemonOnly && _client != null;
  bool get _canUseLegacyQueueFallback => !_shouldSkipLegacyPersistence;

  @override
  void dispose() {
    _sendQueueChangedSub?.cancel();
    _sendQueueItemUpdatedSub?.cancel();
    _connectionChangedSub?.cancel();
    super.dispose();
  }

  Future<bool> _canUseDaemonQueue() async {
    final client = _client;
    if (client == null || !client.isConnected) {
      return false;
    }

    try {
      return await client.supportsSendQueue();
    } catch (error) {
      if (JsonRpcRiftClient.isMethodNotFoundError(error)) {
        return false;
      }
      rethrow;
    }
  }

  Future<void> _refreshFromDaemonQueue() async {
    final client = _client;
    if (client == null) {
      return;
    }
    final listed = await client.listSendQueue();
    final restored = List<Map<String, dynamic>>.from(
      (listed['items'] as List? ?? const <dynamic>[]).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    ).map(SendQueueEntry.fromDaemonQueueMap).whereType<SendQueueEntry>();
    _items
      ..clear()
      ..addAll(restored);
    notifyListeners();
  }

  void _mergeDaemonEntries(Iterable<SendQueueEntry> entries) {
    var changed = false;
    for (final entry in entries) {
      final queueItemId = entry.queueItemId;
      final existingIndex = _items.indexWhere((candidate) {
        if (queueItemId != null &&
            candidate.queueItemId != null &&
            candidate.queueItemId == queueItemId) {
          return true;
        }
        return candidate.localPath == entry.localPath;
      });

      if (existingIndex >= 0) {
        _items[existingIndex] = entry;
      } else {
        _items.add(entry);
      }
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  Future<void> _hydrateMissingDaemonItems(
    Iterable<String> queueItemIds,
  ) async {
    final client = _client;
    if (client == null) {
      return;
    }

    final missingIds = queueItemIds.where((queueItemId) {
      return !_items.any((item) => item.queueItemId == queueItemId);
    }).toList(growable: false);
    if (missingIds.isEmpty) {
      return;
    }

    final recovered = <SendQueueEntry>[];
    for (final queueItemId in missingIds) {
      try {
        final payload = await client.getSendQueueItem(queueItemId);
        if (payload is! Map) {
          continue;
        }
        final entry = SendQueueEntry.fromDaemonQueueMap(
          Map<String, dynamic>.from(payload),
        );
        if (entry != null) {
          recovered.add(entry);
        }
      } catch (_) {
        // Best effort: the enqueue already succeeded, so avoid surfacing a
        // second error if the follow-up read is briefly stale.
      }
    }

    if (recovered.isNotEmpty) {
      _mergeDaemonEntries(recovered);
    }
  }

  Future<SendQueueEntry?> _createProvisionalDaemonEntry(
    Map<String, String> request, {
    required String queueItemId,
    String? status,
    String? targetDeviceId,
  }) async {
    final localPath = request['localPath'];
    if (localPath == null || localPath.isEmpty) {
      return null;
    }

    final file = File(localPath);
    if (!await file.exists()) {
      return null;
    }

    final fallbackFileName = localPath.split(Platform.pathSeparator).last;
    final fallbackMediaType = 'application/octet-stream';
    final entry = SendQueueEntry(
      queueItemId: queueItemId,
      localPath: localPath,
      fileName: request['fileName']?.trim().isNotEmpty == true
          ? request['fileName']!.trim()
          : fallbackFileName,
      mediaType: request['mediaType']?.trim().isNotEmpty == true
          ? request['mediaType']!.trim()
          : fallbackMediaType,
      byteSize: await file.length(),
    );
    entry.targetDeviceId = targetDeviceId;
    entry.status = _queueStatusFromDaemon(status);
    entry.autoRetryWhenPeerAvailable =
        status?.toLowerCase() == 'waiting_for_peer';
    return entry;
  }

  SendQueueStatus _queueStatusFromDaemon(String? status) {
    switch (status?.toLowerCase()) {
      case 'waiting_for_target':
      case 'queued':
      case 'waiting_for_peer':
      case 'dispatching':
        return SendQueueStatus.queued;
      case 'sending':
        return SendQueueStatus.sending;
      case 'sent':
        return SendQueueStatus.sent;
      case 'failed':
      case 'cancelled':
        return SendQueueStatus.failed;
      default:
        return SendQueueStatus.queued;
    }
  }

  Future<bool> supportsDaemonQueue() async {
    await ensureRestored();
    return _canUseDaemonQueue();
  }

  Future<void> refreshFromDaemonIfSupported() async {
    if (await _canUseDaemonQueue()) {
      await _refreshFromDaemonQueue();
    }
  }

  Future<void> restore() async {
    if (_hasRestored) {
      return;
    }

    final inFlight = _restoreFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = _restoreImpl();
    _restoreFuture = future;
    try {
      await future;
    } finally {
      _restoreFuture = null;
    }
  }

  Future<void> _restoreImpl() async {
    if (_hasRestored) {
      return;
    }

    final client = _client;
    if (client != null) {
      try {
        if (await _canUseDaemonQueue()) {
          await _refreshFromDaemonQueue();
          _hasRestored = true;
          return;
        }
      } catch (_) {
        // Fall back to legacy local persistence when daemon queue is unavailable.
      }
    }

    if (_shouldSkipLegacyPersistence) {
      _hasRestored = true;
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppPrefs.sendQueueState);
    if (raw == null || raw.trim().isEmpty) {
      _hasRestored = true;
      return;
    }

    List<dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      await prefs.remove(AppPrefs.sendQueueState);
      _hasRestored = true;
      return;
    }

    final restored = <SendQueueEntry>[];
    for (final item in decoded) {
      if (item is! Map) {
        continue;
      }
      final entry = await SendQueueEntry.fromPersistedEntryMap(
        Map<String, dynamic>.from(item),
      );
      if (entry != null) {
        restored.add(entry);
      }
    }

    _items
      ..clear()
      ..addAll(restored);
    _hasRestored = true;
    await persist();
    notifyListeners();
  }

  Future<void> persist() async {
    if (_shouldSkipLegacyPersistence) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      _items.map((item) => item.toPersistedMap()).toList(growable: false),
    );
    await prefs.setString(AppPrefs.sendQueueState, encoded);
  }

  void replaceAll(Iterable<SendQueueEntry> items) {
    _items
      ..clear()
      ..addAll(items);
    notifyListeners();
  }

  void addAll(Iterable<SendQueueEntry> items) {
    _items.addAll(items);
    notifyListeners();
  }

  void remove(SendQueueEntry item) {
    _items.remove(item);
    notifyListeners();
  }

  void removeWhere(bool Function(SendQueueEntry item) test) {
    _items.removeWhere(test);
    notifyListeners();
  }

  void markDirty() => notifyListeners();

  Future<void> assignTarget(
    SendQueueEntry item, {
    required String targetDeviceId,
  }) async {
    await ensureRestored();

    if (await _canUseDaemonQueue() && item.queueItemId != null) {
      final client = _client!;
      try {
        await client.assignSendQueueTarget(
          queueItemId: item.queueItemId!,
          targetDeviceId: targetDeviceId,
        );
        await _refreshFromDaemonQueue();
        return;
      } catch (error) {
        if (!JsonRpcRiftClient.isMethodNotFoundError(error)) {
          rethrow;
        }
      }
    }

    if (!_canUseLegacyQueueFallback) {
      return;
    }

    item.status = SendQueueStatus.queued;
    item.targetDeviceId = targetDeviceId;
    item.transferId = null;
    item.operationId = null;
    item.bytesTransferred = 0;
    item.errorMessage = null;
    item.autoRetryWhenPeerAvailable = false;
    await persist();
    notifyListeners();
  }

  Future<void> retargetForSelection(SendQueueEntry item) async {
    await ensureRestored();

    if (await _canUseDaemonQueue() && item.queueItemId != null) {
      final client = _client!;
      try {
        await client.removeSendQueueItem(item.queueItemId!);
        await client.enqueueFileSend(
          localPath: item.localPath,
          fileName: item.fileName,
          mediaType: item.mediaType,
        );
        await _refreshFromDaemonQueue();
        return;
      } catch (error) {
        if (!JsonRpcRiftClient.isMethodNotFoundError(error)) {
          rethrow;
        }
      }
    }

    if (!_canUseLegacyQueueFallback) {
      return;
    }

    item.status = SendQueueStatus.queued;
    item.targetDeviceId = null;
    item.transferId = null;
    item.operationId = null;
    item.bytesTransferred = 0;
    item.errorMessage = null;
    item.autoRetryWhenPeerAvailable = false;
    await persist();
    notifyListeners();
  }

  Future<void> retryItem(SendQueueEntry item) async {
    await ensureRestored();

    if (await _canUseDaemonQueue() && item.queueItemId != null) {
      final client = _client!;
      try {
        await client.retrySendQueueItem(item.queueItemId!);
        await _refreshFromDaemonQueue();
        return;
      } catch (error) {
        if (!JsonRpcRiftClient.isMethodNotFoundError(error)) {
          rethrow;
        }
      }
    }

    if (!_canUseLegacyQueueFallback) {
      return;
    }

    item.status = SendQueueStatus.queued;
    item.errorMessage = null;
    item.autoRetryWhenPeerAvailable = false;
    item.transferId = null;
    item.operationId = null;
    item.bytesTransferred = 0;
    await persist();
    notifyListeners();
  }

  Future<void> removeItem(SendQueueEntry item) async {
    await ensureRestored();

    if (await _canUseDaemonQueue() && item.queueItemId != null) {
      final client = _client!;
      try {
        await client.removeSendQueueItem(item.queueItemId!);
        await _refreshFromDaemonQueue();
        return;
      } catch (error) {
        if (!JsonRpcRiftClient.isMethodNotFoundError(error)) {
          rethrow;
        }
      }
    }

    if (!_canUseLegacyQueueFallback) {
      return;
    }

    _items.remove(item);
    await persist();
    notifyListeners();
  }

  Future<void> cancelItem(SendQueueEntry item) async {
    await ensureRestored();

    final client = _client;
    if (client != null &&
        item.transferId != null &&
        item.transferId!.isNotEmpty &&
        !(await _canUseDaemonQueue() && item.queueItemId != null)) {
      await client.cancelFileTransfer(item.transferId!);
    }

    await removeItem(item);
  }

  Future<SendQueueDispatchResult> dispatchToPeer(String deviceId) async {
    await ensureRestored();

    final eligible = eligibleForPeer(deviceId);
    if (eligible.isEmpty) {
      return const SendQueueDispatchResult(submitted: 0, failed: 0);
    }

    if (await _canUseDaemonQueue()) {
      final client = _client!;
      var submitted = 0;
      var failed = 0;
      for (final item in eligible) {
        final queueItemId = item.queueItemId;
        if (queueItemId == null || queueItemId.isEmpty) {
          failed += 1;
          continue;
        }
        try {
          if (item.targetDeviceId == null || item.targetDeviceId != deviceId) {
            await client.assignSendQueueTarget(
              queueItemId: queueItemId,
              targetDeviceId: deviceId,
            );
          } else {
            await client.retrySendQueueItem(queueItemId);
          }
          submitted += 1;
        } catch (_) {
          failed += 1;
        }
      }
      await _refreshFromDaemonQueue();
      return SendQueueDispatchResult(submitted: submitted, failed: failed);
    }

    if (!_canUseLegacyQueueFallback) {
      return SendQueueDispatchResult(
        submitted: 0,
        failed: eligible.length,
      );
    }

    return SendQueueDispatchResult(
      submitted: 0,
      failed: 0,
      legacyItems: eligible,
    );
  }

  Future<SendQueueEnqueueResult> enqueueRequests(
    List<Map<String, String>> requests,
  ) async {
    await ensureRestored();

    final client = _client;
    if (client != null) {
      try {
        if (await _canUseDaemonQueue()) {
          var added = 0;
          var skipped = 0;
          final enqueuedQueueItemIds = <String>[];
          final provisionalEntries = <SendQueueEntry>[];
          for (final request in requests) {
            final localPath = request['localPath'];
            if (localPath == null || localPath.isEmpty) {
              skipped += 1;
              continue;
            }
            try {
              final response = await client.enqueueFileSend(
                localPath: localPath,
                fileName: request['fileName'],
                mediaType: request['mediaType'],
              );
              if (response is Map) {
                final queueItemId = response['queueItemId']?.toString();
                if (queueItemId != null && queueItemId.isNotEmpty) {
                  enqueuedQueueItemIds.add(queueItemId);
                  final provisional = await _createProvisionalDaemonEntry(
                    request,
                    queueItemId: queueItemId,
                    status: response['status']?.toString(),
                    targetDeviceId: response['targetDeviceId']?.toString(),
                  );
                  if (provisional != null) {
                    provisionalEntries.add(provisional);
                  }
                }
              }
              added += 1;
            } catch (_) {
              skipped += 1;
            }
          }
          await _refreshFromDaemonQueue();
          await _hydrateMissingDaemonItems(enqueuedQueueItemIds);
          final stillMissingProvisional = provisionalEntries.where((entry) {
            final queueItemId = entry.queueItemId;
            if (queueItemId == null || queueItemId.isEmpty) {
              return false;
            }
            return !_items.any((item) => item.queueItemId == queueItemId);
          });
          _mergeDaemonEntries(stillMissingProvisional);
          return SendQueueEnqueueResult(added: added, skipped: skipped);
        }
      } catch (error) {
        if (!JsonRpcRiftClient.isMethodNotFoundError(error)) {
          // Fall through only for daemon-queue unavailability; otherwise keep
          // local UX alive rather than dropping the send request entirely.
        }
      }
    }

    if (!_canUseLegacyQueueFallback) {
      return SendQueueEnqueueResult(added: 0, skipped: requests.length);
    }

    var added = 0;
    var skipped = 0;
    final stagedToAdd = <SendQueueEntry>[];
    for (final request in requests) {
      final localPath = request['localPath'];
      if (localPath == null || localPath.isEmpty) {
        skipped += 1;
        continue;
      }
      if (_items.any((item) => item.localPath == localPath)) {
        skipped += 1;
        continue;
      }

      final file = File(localPath);
      if (!await file.exists()) {
        skipped += 1;
        continue;
      }

      stagedToAdd.add(
        SendQueueEntry(
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

    if (stagedToAdd.isNotEmpty) {
      _items.addAll(stagedToAdd);
      await persist();
      notifyListeners();
    }

    return SendQueueEnqueueResult(added: added, skipped: skipped);
  }

  List<SendQueueEntry> eligibleForPeer(String deviceId) {
    return _items.where((item) {
      return SendQueueTargeting.isEligibleForPeer(
        status: item.status,
        targetDeviceId: item.targetDeviceId,
        peerDeviceId: deviceId,
      );
    }).toList(growable: false);
  }

  SendQueuePeerSummary peerSummary(String deviceId) {
    return SendQueueSummary.forPeer(
      peerDeviceId: deviceId,
      items: _items
          .map(
            (item) => SendQueueSummaryEntry(
              status: item.status,
              targetDeviceId: item.targetDeviceId,
              isWaitingForReconnect: item.autoRetryWhenPeerAvailable,
            ),
          )
          .toList(growable: false),
    );
  }
}

class SendQueueEnqueueResult {
  const SendQueueEnqueueResult({
    required this.added,
    required this.skipped,
  });

  final int added;
  final int skipped;

  bool get isEmpty => added == 0;
}

class SendQueueDispatchResult {
  const SendQueueDispatchResult({
    required this.submitted,
    required this.failed,
    this.legacyItems = const <SendQueueEntry>[],
  });

  final int submitted;
  final int failed;
  final List<SendQueueEntry> legacyItems;

  bool get requiresLegacyDispatch => legacyItems.isNotEmpty;
}
