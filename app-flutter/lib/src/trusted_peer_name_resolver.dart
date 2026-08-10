import 'dart:async';

import 'package:flutter/foundation.dart';

String shortDeviceId(String id) =>
    id.length > 12 ? '${id.substring(0, 12)}…' : id;

class TrustedPeerNameResolver {
  TrustedPeerNameResolver({required this.listTrustedPeers});

  final Future<Map<String, dynamic>> Function() listTrustedPeers;
  final Map<String, String> _peerNames = <String, String>{};
  Future<void>? _refreshInFlight;

  Future<void> refresh() {
    final existing = _refreshInFlight;
    if (existing != null) {
      return existing;
    }

    late Future<void> refreshFuture;
    refreshFuture = () async {
      try {
        final result = await listTrustedPeers();
        final names = <String, String>{};
        final peers = result['peers'];
        if (peers is List) {
          for (final peer in peers) {
            if (peer is! Map) {
              continue;
            }
            final deviceId = peer['deviceId']?.toString() ?? '';
            final displayName = peer['displayName']?.toString().trim() ?? '';
            if (deviceId.isNotEmpty && displayName.isNotEmpty) {
              names[deviceId] = displayName;
            }
          }
        }
        _peerNames
          ..clear()
          ..addAll(names);
      } finally {
        if (identical(_refreshInFlight, refreshFuture)) {
          _refreshInFlight = null;
        }
      }
    }();
    _refreshInFlight = refreshFuture;
    return refreshFuture;
  }

  Future<String> resolve(String deviceId) async {
    if (deviceId.isEmpty) {
      return 'Trusted device';
    }

    final cached = _peerNames[deviceId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    try {
      await refresh();
    } catch (error) {
      debugPrint('[Trusted Peer Names] Failed to resolve peer name: $error');
    }

    final refreshed = _peerNames[deviceId];
    return refreshed != null && refreshed.isNotEmpty
        ? refreshed
        : shortDeviceId(deviceId);
  }

  void applyTrustChanged(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString() ?? '';
    if (deviceId.isEmpty) {
      return;
    }

    final newState = event['newState']?.toString().toLowerCase();
    if (newState == 'revoked') {
      _peerNames.remove(deviceId);
      return;
    }

    final displayName = event['displayName']?.toString().trim() ?? '';
    if (displayName.isNotEmpty) {
      _peerNames[deviceId] = displayName;
      return;
    }

    unawaited(_refreshAfterTrustChange());
  }

  void clear() {
    _peerNames.clear();
  }

  Future<void> _refreshAfterTrustChange() async {
    try {
      await refresh();
    } catch (error) {
      debugPrint(
        '[Trusted Peer Names] Failed to refresh after trust change: $error',
      );
    }
  }
}
