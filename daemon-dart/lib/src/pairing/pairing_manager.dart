// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

import '../interfaces/trust_store.dart';
import '../interfaces/identity_manager.dart';
import '../network/session_manager.dart';
import '../crypto/base32_utils.dart';
import '../crypto/cert_decoder.dart';

/// Manages the State Machine for the Pairing process according to the Rift protocol standard.
class PairingManager {
  final TrustStore trustStore;
  final SessionManager sessionManager;
  final IdentityManager identityManager;
  final Map<String, Timer> _pairingTimeouts = {};
  final Set<String> _outboundPairings = {};
  StreamSubscription<ProtocolMessage>? _messageSubscription;
  StreamSubscription<String>? _disconnectSubscription;

  /// Callback to send IPC events back to Flutter UI (via SendPort/Stream)
  final void Function(Map<String, dynamic>) onIpcEvent;

  PairingManager({
    required this.trustStore,
    required this.sessionManager,
    required this.identityManager,
    required this.onIpcEvent,
  }) {
    _messageSubscription = sessionManager.onMessage.listen(_handleNetworkMessage);
    _disconnectSubscription = sessionManager.onPeerDisconnected.listen(_handlePeerDisconnected);
  }

  void _handlePeerDisconnected(String peerDeviceId) async {
    _cancelTimeoutTimer(peerDeviceId);
    final record = await trustStore.getPeer(peerDeviceId);
    if (record != null && record.state == TrustState.pairingPending) {
      await trustStore.transitionState(peerDeviceId, TrustState.pairingPending, TrustState.discovered);
    }
  }

  /// Handles IPC commands received from the Flutter Client
  Future<void> handleIpcCommand(Map<String, dynamic> command) async {
    final method = command['method'] as String?;
    final params = _normalizeParams(command['params']);

    switch (method) {
      case 'rift.startPairing':
        await _startPairing(_requireStringParam(params, 'deviceId'));
        break;
      case 'rift.approvePairing':
        await _approvePairing(
          _requireStringParam(params, 'deviceId'),
          _requireStringParam(params, 'fingerprint'),
        );
        break;
      case 'rift.rejectPairing':
        await _rejectPairing(_requireStringParam(params, 'deviceId'));
        break;
      case 'rift.unpair':
        // Handle trust revocation (revoked)
        await _unpair(
          _requireStringParam(params, 'deviceId'),
          reason: _requireStringParam(params, 'reason'),
        );
        break;
      case 'rift.unblockPeer':
        await _unblockPeer(_requireStringParam(params, 'deviceId'));
        break;
    }
  }

  /// Sends a pairing initialization request to a peer
  Future<void> _startPairing(String peerDeviceId) async {
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) throw StateError('Peer not found in TrustStore');
    if (record.state == TrustState.blocked || record.state == TrustState.revoked) {
      throw StateError('Peer is blocked or revoked');
    }
    
    // Transition state to pairingPending
    await trustStore.transitionState(peerDeviceId, record.state, TrustState.pairingPending);

    // Start 120s timeout countdown
    _startTimeoutTimer(peerDeviceId);
    _outboundPairings.add(peerDeviceId);

    try {
      // Send pairing.start packet via SessionManager
      await sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'pairing.start',
        'sourceDeviceId': identityManager.deviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'expiresInMs': 120000,
          'displayName': 'Rift Device', // TODO: Retrieve from system settings later
        }
      });
    } on StateError {
      _cancelTimeoutTimer(peerDeviceId);
      await trustStore.transitionState(peerDeviceId, TrustState.pairingPending, record.state);
      rethrow;
    } on SocketException {
      _cancelTimeoutTimer(peerDeviceId);
      await trustStore.transitionState(peerDeviceId, TrustState.pairingPending, record.state);
      rethrow;
    }
  }

  /// Called by Flutter App when User clicks "Approve"
  Future<void> _approvePairing(String peerDeviceId, String expectedFingerprint) async {
    _cancelTimeoutTimer(peerDeviceId);
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) throw StateError('Peer not found in TrustStore');
    
    // SECURITY: Cross-check Fingerprint derived directly from TLS Cert stored in DB
    // Prevents UI Spoofing (CVE-2025-xxxx mitigation class)
    final derivedFingerprint = _deriveFingerprint(record.certDer);
    
    if (derivedFingerprint != expectedFingerprint) {
      // Reject immediately if spoofing is detected
      await _rejectPairing(peerDeviceId);
      throw StateError('SecurityError: Fingerprint mismatch. Possible UI spoofing attack. Received: $expectedFingerprint, Expected: $derivedFingerprint');
    }

    final now = DateTime.now().toUtc();

    try {
      // Notify network first; local trust persists only after pairing completion messages are sent.
      await sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'pairing.approve',
        'sourceDeviceId': identityManager.deviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'approvedAt': now.toIso8601String(),
        }
      });

      await sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'pairing.complete',
        'sourceDeviceId': identityManager.deviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'trustedDeviceId': identityManager.deviceId,
          'persistedAt': now.toIso8601String(),
        }
      });
    } on StateError {
      final currentRecord = await trustStore.getPeer(peerDeviceId);
      if (currentRecord?.state == TrustState.pairingPending) {
        _startTimeoutTimer(peerDeviceId);
      }
      rethrow;
    } on SocketException {
      final currentRecord = await trustStore.getPeer(peerDeviceId);
      if (currentRecord?.state == TrustState.pairingPending) {
        _startTimeoutTimer(peerDeviceId);
      }
      rethrow;
    }

    await trustStore.transitionState(
      peerDeviceId,
      record.state,
      TrustState.trusted,
      pairedAt: now,
    );

    // Emit event to Flutter UI
    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onPairingComplete',
      'params': {
        'deviceId': peerDeviceId,
        'fingerprint': expectedFingerprint,
        'persistedAt': now.toIso8601String(),
      }
    });
  }

  /// Called by Flutter App when User clicks "Reject"
  Future<void> _rejectPairing(String peerDeviceId) async {
    _cancelTimeoutTimer(peerDeviceId);
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) return;
    
    if (record.state == TrustState.pairingPending) {
      // Revert to discovered state
      await trustStore.transitionState(peerDeviceId, record.state, TrustState.discovered);
    }

    try {
      await sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'pairing.reject',
        'sourceDeviceId': identityManager.deviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'failureReason': 'PolicyDenied',
          'message': 'User rejected pairing',
        }
      });
    } on StateError {
      // Ignore state errors when rejecting (session may already be gone)
    } on SocketException {
      // Ignore network errors when rejecting
    }
  }
  
  Future<void> _unblockPeer(String peerDeviceId) async {
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) throw StateError('Peer not found in TrustStore');
    if (record.state != TrustState.blocked) {
      throw StateError('Invalid state transition from ${record.state.name} to discovered.');
    }

    await trustStore.transitionState(peerDeviceId, TrustState.blocked, TrustState.discovered);

    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onTrustChanged',
      'params': {
        'deviceId': peerDeviceId,
        'previousState': TrustState.blocked.toJson(),
        'newState': TrustState.discovered.toJson(),
        'reason': 'Peer unblocked by user',
      }
    });
  }

  Future<void> _unpair(String peerDeviceId, {required String reason}) async {
    final record = await trustStore.getPeer(peerDeviceId);
    // Issue 2 fix: throw NotFound so the IPC layer returns -32009 instead of
    // silently reporting success when the peer does not exist in the trust store.
    if (record == null) {
      throw StateError('Peer not found in TrustStore: $peerDeviceId');
    }
    // Transition to revoked
    await trustStore.transitionState(peerDeviceId, record.state, TrustState.revoked);
    sessionManager.disconnectPeer(peerDeviceId);
    
    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onTrustChanged',
      'params': {
        'deviceId': peerDeviceId,
        'previousState': record.state.toJson(),
        'newState': TrustState.revoked.toJson(),
        'reason': reason,
      }
    });
  }

  /// Listens to packets sent from peers via TLS Session
  Future<void> _handleNetworkMessage(ProtocolMessage msg) async {
    final type = msg.payload['type'] as String?;
    final peerDeviceId = msg.peerDeviceId;

    // Ensure peer is stored with the latest certificate before processing
    await _ensurePeerInTrustStore(peerDeviceId, msg.peerCertDer);

    switch (type) {
      case 'pairing.start':
        // Peer requested pairing with us
        final record = await trustStore.getPeer(peerDeviceId);
        final payload = msg.payload['payload'];
        if (payload is! Map<String, dynamic> ||
            payload['expiresInMs'] is! int ||
            (payload['expiresInMs'] as int) <= 0 ||
            payload.containsKey('fingerprint')) {
          sessionManager.disconnectPeer(peerDeviceId);
          return;
        }
        if (record == null) {
          sessionManager.disconnectPeer(peerDeviceId);
          return;
        }
        
        // If blocked or revoked, silently drop the packet
        if (record.state == TrustState.blocked || record.state == TrustState.revoked) {
          return;
        }

        if (record.state != TrustState.discovered) {
          return;
        }

        // According to State Machine, must transition from discovered to pairingPending
        await trustStore.transitionState(peerDeviceId, TrustState.discovered, TrustState.pairingPending);
        
        _startTimeoutTimer(peerDeviceId);
        
        // Issue 4 fix: use the peer's actual expiresInMs rather than a hard-coded 30 000.
        // Clamp to [1 000, 300 000] to guard against pathological values from untrusted peers.
        final rawExpiry = payload['expiresInMs'] as int;
        final clampedExpiry = rawExpiry.clamp(1000, 300000);
        final derivedFingerprint = _deriveFingerprint(record.certDer);
        final displayName = payload['displayName'] as String? ?? 'Unknown Device';

        // Emit event to UI to show popup
        onIpcEvent({
          'jsonrpc': '2.0',
          'method': 'rift.onPairingRequest',
          'params': {
            'deviceId': peerDeviceId,
            'fingerprint': derivedFingerprint,
            'displayName': displayName,
            'expiresInMs': clampedExpiry,
          }
        });
        break;

      case 'pairing.approve':
        final approvePayload = msg.payload['payload'];
        if (approvePayload is! Map<String, dynamic> ||
            approvePayload['approvedAt'] is! String ||
            approvePayload.containsKey('fingerprint')) {
          sessionManager.disconnectPeer(peerDeviceId);
          return;
        }
        // SECURITY: Prevent Double-Approve Bypass
        // Only process pairing.approve if we initiated pairing (Outbound)
        if (!_outboundPairings.contains(peerDeviceId)) {
          // Peer sent approve but we are not the initiator -> Reject immediately
          await _rejectPairing(peerDeviceId);
          return;
        }

        _cancelTimeoutTimer(peerDeviceId, clearOutbound: false);

        final record = await trustStore.getPeer(peerDeviceId);
        if (record?.state == TrustState.pairingPending) {
          _startTimeoutTimer(peerDeviceId);
        }
        break;

      case 'pairing.reject':
        final rejectPayload = msg.payload['payload'];
        if (rejectPayload is! Map<String, dynamic> ||
            rejectPayload['failureReason'] is! String ||
            rejectPayload.containsKey('fingerprint')) {
          sessionManager.disconnectPeer(peerDeviceId);
          return;
        }
        _cancelTimeoutTimer(peerDeviceId);
        _outboundPairings.remove(peerDeviceId);
        final record = await trustStore.getPeer(peerDeviceId);
        if (record?.state == TrustState.pairingPending) {
           await trustStore.transitionState(peerDeviceId, TrustState.pairingPending, TrustState.discovered);
           // Optionally emit event to notify UI of rejection
        }
        break;
        
      case 'pairing.complete':
        final record = await trustStore.getPeer(peerDeviceId);
        if (record == null) {
          return;
        }

        final completePayload = msg.payload['payload'];
        if (completePayload is! Map<String, dynamic> ||
            completePayload['trustedDeviceId'] is! String ||
            completePayload['persistedAt'] is! String ||
            completePayload.containsKey('fingerprint')) {
          sessionManager.disconnectPeer(peerDeviceId);
          return;
        }

        final trustedDeviceId = completePayload['trustedDeviceId'] as String;
        if (trustedDeviceId != peerDeviceId) {
          await _rejectPairing(peerDeviceId);
          return;
        }

        if (record.state == TrustState.pairingPending) {
          _cancelTimeoutTimer(peerDeviceId);
          _outboundPairings.remove(peerDeviceId);
          final now = DateTime.now().toUtc();
          await trustStore.transitionState(
            peerDeviceId,
            TrustState.pairingPending,
            TrustState.trusted,
            pairedAt: now,
          );
          onIpcEvent({
            'jsonrpc': '2.0',
            'method': 'rift.onPairingComplete',
            'params': {
              'deviceId': peerDeviceId,
              'fingerprint': _deriveFingerprint(record.certDer),
              'persistedAt': now.toIso8601String(),
            }
          });
        }
        break;
    }
  }

  Future<void> _ensurePeerInTrustStore(String peerDeviceId, Uint8List? certDer) async {
    if (certDer == null) return;
    
    var record = await trustStore.getPeer(peerDeviceId);
    if (record == null) {
      record = PeerRecord(
        deviceId: peerDeviceId,
        displayName: 'Rift Device',
        certDer: certDer,
        state: TrustState.discovered,
        updatedAt: DateTime.now().toUtc(),
      );
      await trustStore.upsertPeer(record);
    } else {
      // Trusted, blocked, and revoked peers keep their pinned certificate until
      // an explicit re-pair / trust-state reset occurs.
      if (record.state == TrustState.trusted ||
          record.state == TrustState.blocked ||
          record.state == TrustState.revoked) {
        return;
      }

      // Discovered and pairing-pending peers may still refresh their transient
      // certificate context before trust is finalized.
      final updatedRecord = PeerRecord(
        deviceId: record.deviceId,
        displayName: record.displayName,
        certDer: certDer,
        state: record.state,
        pairedAt: record.pairedAt,
        updatedAt: DateTime.now().toUtc(),
      );
      await trustStore.upsertPeer(updatedRecord);
    }
  }

  void _startTimeoutTimer(String peerDeviceId) {
    _cancelTimeoutTimer(peerDeviceId);
    _pairingTimeouts[peerDeviceId] = Timer(const Duration(seconds: 120), () {
      _rejectPairing(peerDeviceId); // Auto reject after 120 seconds
    });
  }

  void _cancelTimeoutTimer(String peerDeviceId, {bool clearOutbound = true}) {
    _pairingTimeouts[peerDeviceId]?.cancel();
    _pairingTimeouts.remove(peerDeviceId);
    if (clearOutbound) {
      _outboundPairings.remove(peerDeviceId);
    }
  }

  Future<void> dispose() async {
    for (final timer in _pairingTimeouts.values) {
      timer.cancel();
    }
    _pairingTimeouts.clear();
    _outboundPairings.clear();
    await _messageSubscription?.cancel();
    await _disconnectSubscription?.cancel();
  }

  String _requireStringParam(Map<String, dynamic> params, String key) {
    final value = params[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError.value(value, key, 'must be a non-empty string');
    }
    return value;
  }

  Map<String, dynamic> _normalizeParams(Object? params) {
    if (params == null) {
      return <String, dynamic>{};
    }
    if (params is Map) {
      return params.map((key, value) => MapEntry(key.toString(), value));
    }
    throw ArgumentError.value(params, 'params', 'must be an object');
  }

  String _deriveFingerprint(Uint8List certDer) {
    final peerPublicKey = RiftCertDecoder.extractEd25519PublicKeyFromDer(certDer);
    final hash = sha256.convert(peerPublicKey).bytes;
    // Protocol Section 3.2: Base32(SHA-256(Ed25519)), uppercase, truncated to 32 chars, hyphenated groups of 4
    final base32Str = Base32Utils.encode(Uint8List.fromList(hash)).toUpperCase().replaceAll('=', '');
    final truncated = base32Str.substring(0, 32);
    final hyphenated = truncated.replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)}-');
    return hyphenated.substring(0, 39); // Remove trailing hyphen
  }
}
