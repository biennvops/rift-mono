import 'dart:async';
import 'package:flutter/material.dart';

import '../ipc/json_rpc_client.dart';
import '../platform/notification_route.dart';
import '../platform/android_shell.dart';
import '../platform/windows_shell.dart';
import '../platform/linux_notifications.dart';
import '../platform/macos_notifications.dart';

class NotificationSyncCoordinator {
  final JsonRpcRiftClient client;

  StreamSubscription<Map<String, dynamic>>? _notificationPostedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationUpdatedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationRemovedSub;

  final List<Map<String, dynamic>> _pendingNotificationSyncEvents =
      <Map<String, dynamic>>[];
  bool _isFlushingNotificationSyncEvents = false;

  final List<Map<String, String>> _pendingDesktopNotificationActions =
      <Map<String, String>>[];

  NotificationSyncCoordinator({
    required this.client,
  });

  void init() {
    _bindIpcEvents();
  }

  void dispose() {
    _notificationPostedSub?.cancel();
    _notificationUpdatedSub?.cancel();
    _notificationRemovedSub?.cancel();
  }

  void _bindIpcEvents() {
    _notificationPostedSub = client.onNotificationPosted.listen((event) {
      showMirroredNotificationPreview(event);
    });

    _notificationUpdatedSub = client.onNotificationUpdated.listen((event) {
      // History UI refreshes from its own stream binding; updates do not raise a
      // second native popup to avoid noisy duplicates.
    });

    _notificationRemovedSub = client.onNotificationRemoved.listen((event) {
      // Native notifications are best-effort previews; removal only updates the
      // in-app history state.
    });
  }

  String? _notificationSyncEventSignature(Map<String, dynamic> event) {
    final eventType = event['eventType']?.toString();
    final notificationId = event['notificationId']?.toString();
    if (eventType == null ||
        eventType.isEmpty ||
        notificationId == null ||
        notificationId.isEmpty) {
      return null;
    }
    final timestamp =
        (event['postedAt'] ?? event['removedAt'])?.toString() ?? '';
    return '$eventType\n$notificationId\n$timestamp';
  }

  void _enqueueNotificationSyncEvent(Map<String, dynamic> event) {
    final signature = _notificationSyncEventSignature(event);
    if (signature != null) {
      final alreadyQueued = _pendingNotificationSyncEvents.any(
        (queued) => _notificationSyncEventSignature(queued) == signature,
      );
      if (alreadyQueued) {
        return;
      }
    }
    _pendingNotificationSyncEvents.add(Map<String, dynamic>.from(event));
  }

  Future<void> submitNativeNotificationSyncEvent(
    Map<String, dynamic> event,
  ) async {
    final eventType = event['eventType']?.toString();
    final notificationId = event['notificationId']?.toString();
    if (eventType == null ||
        eventType.isEmpty ||
        notificationId == null ||
        notificationId.isEmpty) {
      return;
    }

    _enqueueNotificationSyncEvent(event);
    await flushPendingNotificationSyncEvents();
  }

  Future<void> flushPendingNotificationSyncEvents() async {
    if (_isFlushingNotificationSyncEvents) {
      return;
    }
    _isFlushingNotificationSyncEvents = true;
    try {
      while (_pendingNotificationSyncEvents.isNotEmpty) {
        if (!client.isConnected) {
          client.connect().catchError((Object error, StackTrace stackTrace) {
            debugPrint(
              '[Notification Sync] Failed to reconnect for native event send: $error',
            );
          });
          return;
        }

        final event = _pendingNotificationSyncEvents.first;
        final eventType = event['eventType']?.toString() ?? '';
        try {
          await client.notifyLocalNotificationEvent(
            eventType: eventType,
            payload: Map<String, Object?>.from(event),
          );
          _pendingNotificationSyncEvents.removeAt(0);
        } catch (error) {
          debugPrint(
            '[Notification Sync] Failed to submit native notification event: $error',
          );
          return;
        }
      }
    } finally {
      _isFlushingNotificationSyncEvents = false;
    }
  }

  void _queuePendingDesktopNotificationAction({
    required String notificationId,
    required String action,
  }) {
    final alreadyQueued = _pendingDesktopNotificationActions.any(
      (candidate) =>
          candidate['notificationId'] == notificationId &&
          candidate['action'] == action,
    );
    if (alreadyQueued) {
      return;
    }
    _pendingDesktopNotificationActions.add(<String, String>{
      'notificationId': notificationId,
      'action': action,
    });
  }

  Future<bool> submitDesktopNotificationAction({
    required String notificationId,
    required String action,
    bool queueIfUnavailable = true,
  }) async {
    if (!client.isConnected) {
      if (queueIfUnavailable) {
        _queuePendingDesktopNotificationAction(
          notificationId: notificationId,
          action: action,
        );
      }
      client.connect().catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          '[Notification Sync] Failed to reconnect for notification action: $error',
        );
      });
      return false;
    }

    try {
      await client.performNotificationAction(
        notificationId: notificationId,
        action: action,
      );
      return true;
    } catch (error) {
      debugPrint(
        '[Notification Sync] Failed to perform mirrored notification action: $error',
      );
      if (queueIfUnavailable) {
        _queuePendingDesktopNotificationAction(
          notificationId: notificationId,
          action: action,
        );
      }
      return false;
    }
  }

  Future<void> flushPendingDesktopNotificationActions() async {
    if (_pendingDesktopNotificationActions.isEmpty) {
      return;
    }

    final queued = List<Map<String, String>>.from(
      _pendingDesktopNotificationActions,
    );
    _pendingDesktopNotificationActions.clear();
    for (final actionPayload in queued) {
      final notificationId = actionPayload['notificationId'];
      final action = actionPayload['action'];
      if (notificationId != null && action != null) {
        await submitDesktopNotificationAction(
          notificationId: notificationId,
          action: action,
          queueIfUnavailable: false,
        );
      }
    }
  }

  List<DesktopNotificationAction> _buildMirroredNotificationActions(
    Map<String, dynamic> event,
  ) {
    final actions = <DesktopNotificationAction>[];
    if (event['isOpenable'] == true) {
      actions.add(
        const DesktopNotificationAction(id: 'open', title: 'Open'),
      );
    }
    if (event['isDismissible'] == true) {
      actions.add(
        const DesktopNotificationAction(id: 'dismiss', title: 'Dismiss'),
      );
    }
    return actions;
  }

  void showMirroredNotificationPreview(Map<String, dynamic> event) {
    final notificationId = event['notificationId']?.toString();
    if (notificationId == null || notificationId.isEmpty) {
      return;
    }
    final title = event['title']?.toString().trim();
    final body = event['bodyPreview']?.toString().trim();
    final appName = event['appName']?.toString().trim();
    final sourceDeviceId = event['sourceDeviceId']?.toString();
    final mirroredPayload = <String, Object?>{
      'route': NotificationRoute.historyNotifications,
      'notificationId': notificationId,
      if (sourceDeviceId != null && sourceDeviceId.isNotEmpty)
        'sourceDeviceId': sourceDeviceId,
      if (appName != null && appName.isNotEmpty) 'appName': appName,
      'isOpenable': event['isOpenable'] == true,
      'isDismissible': event['isDismissible'] == true,
    };
    final mirroredActions = _buildMirroredNotificationActions(event);
    final notificationTitle = (title != null && title.isNotEmpty)
        ? title
        : ((appName != null && appName.isNotEmpty) ? appName : 'Notification');
    final notificationBody = [
      if (sourceDeviceId != null && sourceDeviceId.isNotEmpty) sourceDeviceId,
      if (body != null && body.isNotEmpty) body,
    ].join(' • ');

    unawaited(() async {
      try {
        if (AndroidShell.isSupported) {
          final sourcePlatform = event['sourcePlatform']?.toString();
          if (sourcePlatform != 'windows' &&
              sourcePlatform != 'macos' &&
              sourcePlatform != 'linux') {
            return;
          }
          await AndroidShell.showNotification(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
          );
          return;
        }
        if (WindowsShell.isSupported) {
          await WindowsShell.showNotification(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
          );
          return;
        }
        if (LinuxNotifications.isSupported) {
          await LinuxNotifications.show(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
            actions: mirroredActions,
          );
          return;
        }
        if (MacOSNotifications.isSupported) {
          await MacOSNotifications.show(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
            actions: mirroredActions,
          );
        }
      } catch (_) {
        // Best-effort: depends on user permission and runner support.
      }
    }());
  }
}
