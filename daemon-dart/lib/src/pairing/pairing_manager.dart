// ignore_for_file: prefer_initializing_formals

import 'dart:async';
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
    final params = command['params'] as Map<String, dynamic>? ?? {};

    switch (method) {
      case 'rift.startPairing':
        await _startPairing(params['deviceId'] as String);
        break;
      case 'rift.approvePairing':
        await _approvePairing(
          params['deviceId'] as String,
          params['fingerprint'] as String,
        );
        break;
      case 'rift.rejectPairing':
        await _rejectPairing(params['deviceId'] as String);
        break;
      case 'rift.unpair':
        // Handle trust revocation (revoked)
        await _unpair(params['deviceId'] as String);
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

    // Start 30s timeout countdown
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
          'expiresInMs': 30000,
          'displayName': 'Rift Device', // TODO: Retrieve from system settings later
        }
      });
    } catch (e) {
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
    } catch (e) {
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
    } catch (e) {
      // Ignore network errors when rejecting
    }
  }
  
  Future<void> _unpair(String peerDeviceId) async {
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) return;
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
        'reason': 'User requested unpair',
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
        
        // If blocked or revoked, silently drop the packet
        if (record!.state == TrustState.blocked || record.state == TrustState.revoked) {
          return;
        }

        if (record.state != TrustState.discovered) {
          return;
        }

        // According to State Machine, must transition from discovered to pairingPending
        await trustStore.transitionState(peerDeviceId, TrustState.discovered, TrustState.pairingPending);
        
        _startTimeoutTimer(peerDeviceId);
        
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
            'expiresInMs': 30000, // 30 seconds timeout
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
      // Update cert if peer reconnected with a new one
      final updatedRecord = PeerRecord(
        deviceId: record.deviceId,
        displayName: record.displayName,
        certDer: certDer, // Cert may change (TLS rotating)
        state: record.state,
        pairedAt: record.pairedAt,
        updatedAt: DateTime.now().toUtc(),
      );
      await trustStore.upsertPeer(updatedRecord);
    }
  }

  void _startTimeoutTimer(String peerDeviceId) {
    _cancelTimeoutTimer(peerDeviceId);
    _pairingTimeouts[peerDeviceId] = Timer(const Duration(seconds: 30), () {
      _rejectPairing(peerDeviceId); // Auto reject after 30 seconds
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
