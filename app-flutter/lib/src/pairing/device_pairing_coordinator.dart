import 'dart:async';
import 'package:flutter/material.dart';
import '../ipc/json_rpc_client.dart';
import '../platform/notification_route.dart';
import '../../screens/pairing_screen.dart';
import '../ui/app_shell.dart';

class DevicePairingCoordinator {
  final JsonRpcRiftClient client;
  final GlobalKey<NavigatorState> navigatorKey;
  final GlobalKey<AppShellState> appShellKey;
  final void Function(String title, String body) onNotify;
  final void Function({
    required String title,
    required String body,
    String? route,
    Map<String, Object?>? payload,
  }) onNotifyWithRoute;

  StreamSubscription<Map<String, dynamic>>? _pairingRequestSub;
  StreamSubscription<Map<String, dynamic>>? _pairingCompleteSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;

  String? _activePairingDeviceId;
  bool _mounted = true;

  DevicePairingCoordinator({
    required this.client,
    required this.navigatorKey,
    required this.appShellKey,
    required this.onNotify,
    required this.onNotifyWithRoute,
  });

  void init() {
    _bindPairingRequests();
    _bindTrustEvents();
  }

  void dispose() {
    _mounted = false;
    _pairingRequestSub?.cancel();
    _pairingCompleteSub?.cancel();
    _trustChangedSub?.cancel();
  }

  void _bindTrustEvents() {
    _trustChangedSub = client.onTrustChanged.listen((event) {
      final deviceId = event['deviceId']?.toString() ?? 'unknown device';
      final newState = event['newState']?.toString();
      if (newState == null || newState.isEmpty) return;
      onNotify('Trust updated', '$deviceId is now $newState.');
    });

    _pairingCompleteSub = client.onPairingComplete.listen((event) {
      final deviceId = event['deviceId']?.toString() ?? 'trusted device';
      final displayName = event['displayName']?.toString();
      final label = (displayName != null && displayName.isNotEmpty)
          ? displayName
          : deviceId;
      onNotifyWithRoute(
        title: 'Pairing completed',
        body: 'Connected to $label.',
        route: NotificationRoute.devices,
      );
    });
  }

  void _bindPairingRequests() {
    _pairingRequestSub = client.onPairingRequest.listen((event) {
      if (!_mounted) return;

      final deviceId = event['deviceId']?.toString();
      if (deviceId == null || deviceId.isEmpty) return;

      final displayName = event['displayName']?.toString();
      onNotifyWithRoute(
        title: 'Pairing request',
        body: displayName == null || displayName.isEmpty
            ? 'Incoming pairing request.'
            : 'Incoming pairing request from $displayName.',
        route: NotificationRoute.pairing,
        payload: <String, Object?>{
          'deviceId': deviceId,
          if (displayName != null && displayName.isNotEmpty)
            'displayName': displayName,
          if (event['fingerprint'] != null)
            'fingerprint': event['fingerprint'].toString(),
          if (event['expiresInMs'] != null)
            'expiresInMs': event['expiresInMs'] as Object,
        },
      );
      openIncomingPairingRequest({
        'deviceId': deviceId,
        'displayName': displayName,
        'fingerprint': event['fingerprint']?.toString(),
        'expiresInMs': event['expiresInMs'],
      });
    });
  }

  void openIncomingPairingRequest(Map<String, dynamic> payload) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      return;
    }

    final deviceId = payload['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }
    if (_activePairingDeviceId == deviceId) {
      return;
    }

    _activePairingDeviceId = deviceId;
    showDialog<dynamic>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => PairingScreen(
        initialDeviceId: deviceId,
        initialDisplayName: payload['displayName']?.toString(),
        initialPeerFingerprint: payload['fingerprint']?.toString(),
        initialExpiresInMs: (payload['expiresInMs'] as num?)?.toInt(),
        initialCanApproveLocally: true,
        initialStatus: 'Incoming pairing request',
      ),
    ).then((result) {
      if (_mounted) {
        if (result == 'history') {
          appShellKey.currentState
              ?.showHistoryRoute(NotificationRoute.historyClipboard);
        } else if (result == 'devices') {
          appShellKey.currentState?.showRoute(NotificationRoute.devices);
        }
        if (_activePairingDeviceId == deviceId) {
          _activePairingDeviceId = null;
        }
      }
    });
  }
}
