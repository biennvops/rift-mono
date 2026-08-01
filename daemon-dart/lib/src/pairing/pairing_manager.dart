// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

import '../core/rift_exceptions.dart';
import '../core/rift_log.dart';
import '../interfaces/trust_store.dart';
import '../interfaces/identity_manager.dart';
import '../network/session_manager.dart';
import '../crypto/base32_utils.dart';
import '../crypto/cert_decoder.dart';
import '../core/rpc_utils.dart';

/// Manages the State Machine for the Pairing process according to the Rift protocol standard.
class PairingManager {
  static const Duration _disconnectGracePeriod = Duration(milliseconds: 1500);

  final TrustStore trustStore;
  final SessionManager sessionManager;
  final IdentityManager identityManager;
  final Map<String, Timer> _pairingTimeouts = {};
  final Set<String> _outboundPairings = {};
  final Set<String> _localApprovals = {};
  final Set<String> _remoteApprovals = {};
  final Set<String> _completionSent = {};
  static const int _pairingTimeoutSeconds = 30;
  StreamSubscription<ProtocolMessage>? _messageSubscription;
  StreamSubscription<String>? _disconnectSubscription;

  /// Callback to send IPC events back to Flutter UI (via SendPort/Stream)
  final void Function(Map<String, dynamic>) onIpcEvent;
  final Future<void> Function(String peerDeviceId)? onPeerTrusted;

  PairingManager({
    required this.trustStore,
    required this.sessionManager,
    required this.identityManager,
    required this.onIpcEvent,
    this.onPeerTrusted,
  }) {
    _messageSubscription = sessionManager.onMessage.listen(
      _handleNetworkMessage,
    );
    _disconnectSubscription = sessionManager.onPeerDisconnected.listen(
      _handlePeerDisconnected,
    );
  }

  void _handlePeerDisconnected(String peerDeviceId) async {
    try {
      await Future<void>.delayed(_disconnectGracePeriod);
      final ctx = sessionManager.getContext(peerDeviceId);
      if (ctx != null && ctx.handshakeState == HandshakeState.established) {
        RiftLog.info(
          '[Pairing] Ignoring transient disconnect for $peerDeviceId because an authenticated replacement session is already established',
        );
        return;
      }

      _cancelTimeoutTimer(peerDeviceId);
      final record = await trustStore.getPeer(peerDeviceId);
      if (record != null && record.state == TrustState.pairingPending) {
        await trustStore.transitionState(
          peerDeviceId,
          TrustState.pairingPending,
          TrustState.discovered,
        );
      }
    } catch (e, stackTrace) {
      // Best-effort cleanup only, but log for observability.
      RiftLog.warn(
        '[Pairing] Failed to handle peer disconnect for $peerDeviceId',
      );
      RiftLog.error(
        '[Pairing] Peer disconnect cleanup exception',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Handles IPC commands received from the Flutter Client
  Future<void> handleIpcCommand(Map<String, dynamic> command) async {
    final method = command['method'] as String?;
    final params = RpcUtils.normalizeParams(command['params']);

    switch (method) {
      case 'rift.startPairing':
        await _startPairing(RpcUtils.requireStringParam(params, 'deviceId'));
        break;
      case 'rift.approvePairing':
        await _approvePairing(
          RpcUtils.requireStringParam(params, 'deviceId'),
          RpcUtils.requireStringParam(params, 'fingerprint'),
        );
        break;
      case 'rift.rejectPairing':
        await _rejectPairing(RpcUtils.requireStringParam(params, 'deviceId'));
        break;
      case 'rift.unpair':
        await _unpair(
          RpcUtils.requireStringParam(params, 'deviceId'),
          reason: RpcUtils.requireStringParam(params, 'reason'),
        );
        break;
      case 'rift.unblockPeer':
        await _unblockPeer(RpcUtils.requireStringParam(params, 'deviceId'));
        break;
      case 'rift.resetRevokedPeer':
        await _resetRevokedPeer(
          RpcUtils.requireStringParam(params, 'deviceId'),
        );
        break;
    }
  }

  /// Sends a pairing initialization request to a peer
  Future<void> _startPairing(String peerDeviceId) async {
    RiftLog.debug('[Pairing] Sending pairing.start to $peerDeviceId');
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }
    if (record.state == TrustState.revoked) {
      await trustStore.deletePeer(peerDeviceId);
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }
    if (record.state == TrustState.blocked) {
      throw const RiftUnauthorizedException('Peer is blocked');
    }

    // Transition state to pairingPending
    await trustStore.transitionState(
      peerDeviceId,
      record.state,
      TrustState.pairingPending,
    );

    // Start the local timeout countdown using the advertised outbound expiry.
    _startTimeoutTimer(peerDeviceId);
    _outboundPairings.add(peerDeviceId);
    _localApprovals.add(peerDeviceId);

    try {
      RiftLog.debug(
        '[Pairing] About to send pairing.start to $peerDeviceId '
        'state=${record.state.toJson()} outbound=${_outboundPairings.contains(peerDeviceId)}',
      );
      // Send pairing.start packet via SessionManager
      await sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'pairing.start',
        'sourceDeviceId': identityManager.deviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'expiresInMs': _pairingTimeoutSeconds * 1000,
          'displayName': identityManager.displayName,
        },
      });
      RiftLog.debug('[Pairing] pairing.start sent to $peerDeviceId');
    } on StateError {
      _cancelTimeoutTimer(peerDeviceId);
      _localApprovals.remove(peerDeviceId);
      await trustStore.transitionState(
        peerDeviceId,
        TrustState.pairingPending,
        record.state,
      );
      RiftLog.warn(
        '[Pairing] pairing.start failed with StateError for $peerDeviceId',
      );
      rethrow;
    } on SocketException {
      _cancelTimeoutTimer(peerDeviceId);
      _localApprovals.remove(peerDeviceId);
      await trustStore.transitionState(
        peerDeviceId,
        TrustState.pairingPending,
        record.state,
      );
      RiftLog.warn(
        '[Pairing] pairing.start failed with SocketException for $peerDeviceId',
      );
      rethrow;
    } on SessionException {
      _cancelTimeoutTimer(peerDeviceId);
      _localApprovals.remove(peerDeviceId);
      await trustStore.transitionState(
        peerDeviceId,
        TrustState.pairingPending,
        record.state,
      );
      RiftLog.warn(
        '[Pairing] pairing.start failed with SessionException for $peerDeviceId',
      );
      rethrow;
    }
  }

  /// Called by Flutter App when User clicks "Approve"
  Future<void> _approvePairing(
    String peerDeviceId,
    String expectedFingerprint,
  ) async {
    RiftLog.debug('[Pairing] Approving pairing with $peerDeviceId');
    _cancelTimeoutTimer(peerDeviceId, clearOutbound: false);
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }

    // SECURITY: Cross-check Fingerprint derived directly from TLS Cert stored in DB
    // Prevents UI Spoofing (CVE-2025-xxxx mitigation class)
    final derivedFingerprint = _deriveFingerprint(record.certDer);

    if (derivedFingerprint != expectedFingerprint) {
      // Reject immediately if spoofing is detected
      await _rejectPairing(peerDeviceId);
      throw RiftAuthenticationFailedException(
        'SecurityError: Fingerprint mismatch. Possible UI spoofing attack. Received: $expectedFingerprint, Expected: $derivedFingerprint',
      );
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
        'payload': {'approvedAt': now.toIso8601String()},
      });
      _localApprovals.add(peerDeviceId);
      await _sendPairingCompleteIfReady(peerDeviceId, now.toIso8601String());
    } catch (e) {
      final currentRecord = await trustStore.getPeer(peerDeviceId);
      if (currentRecord?.state == TrustState.pairingPending) {
        _startTimeoutTimer(peerDeviceId);
      }
      rethrow;
    }

    if (!_localApprovals.contains(peerDeviceId) ||
        !_remoteApprovals.contains(peerDeviceId)) {
      _startTimeoutTimer(
        peerDeviceId,
        timeout: const Duration(seconds: _pairingTimeoutSeconds),
        clearOutbound: false,
      );
      return;
    }

    await trustStore.transitionState(
      peerDeviceId,
      record.state,
      TrustState.trusted,
      pairedAt: now,
    );
    sessionManager.updateTrustState(peerDeviceId, TrustState.trusted);
    await onPeerTrusted?.call(peerDeviceId);

    _localApprovals.remove(peerDeviceId);
    _remoteApprovals.remove(peerDeviceId);
    _completionSent.remove(peerDeviceId);

    // Emit event to Flutter UI
    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onPairingComplete',
      'params': {
        'deviceId': peerDeviceId,
        'fingerprint': expectedFingerprint,
        'persistedAt': now.toIso8601String(),
      },
    });
  }

  /// Called by Flutter App when User clicks "Reject"
  Future<void> _rejectPairing(String peerDeviceId) async {
    RiftLog.debug('[Pairing] Rejecting pairing with $peerDeviceId');
    _cancelTimeoutTimer(peerDeviceId);
    _localApprovals.remove(peerDeviceId);
    _remoteApprovals.remove(peerDeviceId);
    _completionSent.remove(peerDeviceId);
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) return;

    if (record.state == TrustState.pairingPending) {
      // Revert to discovered state
      await trustStore.transitionState(
        peerDeviceId,
        record.state,
        TrustState.discovered,
      );
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
        },
      });
    } on StateError {
      // Ignore state errors when rejecting (session may already be gone)
    } on SocketException {
      // Ignore network errors when rejecting
    }
  }

  Future<void> _unblockPeer(String peerDeviceId) async {
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }
    if (record.state != TrustState.blocked) {
      throw RiftInvalidTransitionException(
        'Invalid state transition from ${record.state.name} to discovered.',
      );
    }

    await trustStore.transitionState(
      peerDeviceId,
      TrustState.blocked,
      TrustState.discovered,
    );

    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onTrustChanged',
      'params': {
        'deviceId': peerDeviceId,
        'previousState': TrustState.blocked.toJson(),
        'newState': TrustState.discovered.toJson(),
        'reason': 'Peer unblocked by user',
      },
    });
  }

  Future<void> _unpair(String peerDeviceId, {required String reason}) async {
    final record = await trustStore.getPeer(peerDeviceId);
    // Issue 2 fix: throw NotFound so the IPC layer returns -32009 instead of
    // silently reporting success when the peer does not exist in the trust store.
    if (record == null) {
      throw RiftNotFoundException(
        'Peer not found in TrustStore: $peerDeviceId',
      );
    }
    final removedAt = DateTime.now().toUtc();
    await _notifyPeerTrustRemoved(
      peerDeviceId,
      removedAt: removedAt,
      reason: reason,
    );
    await trustStore.deletePeer(peerDeviceId);
    sessionManager.disconnectPeer(peerDeviceId);

    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onTrustChanged',
      'params': {
        'deviceId': peerDeviceId,
        'previousState': record.state.toJson(),
        'newState': 'removed',
        'reason': reason,
      },
    });
  }

  Future<void> _notifyPeerTrustRemoved(
    String peerDeviceId, {
    required DateTime removedAt,
    required String reason,
  }) async {
    try {
      await sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'trust.remove',
        'sourceDeviceId': identityManager.deviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'removedDeviceId': peerDeviceId,
          'reason': reason,
          'removedAt': removedAt.toIso8601String(),
        },
      });
    } catch (error, stackTrace) {
      RiftLog.warn(
        '[Pairing] Failed to send advisory trust.remove to $peerDeviceId: $error',
      );
      RiftLog.error(
        '[Pairing] trust.remove send failure',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _resetRevokedPeer(String peerDeviceId) async {
    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }
    if (record.state != TrustState.revoked) {
      throw RiftInvalidTransitionException(
        'Invalid state transition from ${record.state.name} to discovered.',
      );
    }

    await trustStore.deletePeer(peerDeviceId);

    onIpcEvent({
      'jsonrpc': '2.0',
      'method': 'rift.onTrustChanged',
      'params': {
        'deviceId': peerDeviceId,
        'previousState': TrustState.revoked.toJson(),
        'newState': 'removed',
        'reason': 'Legacy revoked peer removed by user',
      },
    });
  }

  /// Listens to packets sent from peers via TLS Session
  Future<void> _handleNetworkMessage(ProtocolMessage msg) async {
    final type = msg.payload['type'] as String?;
    final peerDeviceId = msg.peerDeviceId;
    RiftLog.debug(
      '[Pairing] Received network message ${type ?? "<unknown>"} from $peerDeviceId',
    );

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

        if (record.state == TrustState.revoked) {
          await trustStore.deletePeer(peerDeviceId);
        }

        // If blocked, silently drop the packet
        if (record.state == TrustState.blocked) {
          return;
        }

        if (record.state != TrustState.discovered &&
            record.state != TrustState.pairingPending) {
          return;
        }

        // Pairing requests may arrive while we are already in pairingPending
        // due to simultaneous/manual pairing attempts. In that case we still
        // need to surface the incoming request to UI so the user can approve.
        if (record.state == TrustState.discovered) {
          await trustStore.transitionState(
            peerDeviceId,
            TrustState.discovered,
            TrustState.pairingPending,
          );
        }
        _remoteApprovals.add(peerDeviceId);

        // Issue 4 fix: use the peer's actual expiresInMs rather than a hard-coded 30 000.
        // Clamp to [1 000, 300 000] to guard against pathological values from untrusted peers.
        final rawExpiry = payload['expiresInMs'] as int;
        final clampedExpiry = rawExpiry.clamp(1000, 300000);
        _startTimeoutTimer(
          peerDeviceId,
          timeout: Duration(milliseconds: clampedExpiry),
        );
        final derivedFingerprint = _deriveFingerprint(record.certDer);
        final receivedDisplayName = payload['displayName'];
        final displayName =
            receivedDisplayName is String &&
                receivedDisplayName.trim().isNotEmpty
            ? receivedDisplayName.trim()
            : null;
        if (displayName != null) {
          await trustStore.updateDisplayName(peerDeviceId, displayName);
        }

        // Emit event to UI to show popup
        onIpcEvent({
          'jsonrpc': '2.0',
          'method': 'rift.onPairingRequest',
          'params': {
            'deviceId': peerDeviceId,
            'fingerprint': derivedFingerprint,
            'displayName':
                displayName ?? record.displayName ?? 'Unknown Device',
            'expiresInMs': clampedExpiry,
          },
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
        _remoteApprovals.add(peerDeviceId);
        await _sendPairingCompleteIfReady(
          peerDeviceId,
          approvePayload['approvedAt'] as String,
        );
        onIpcEvent({
          'jsonrpc': '2.0',
          'method': 'rift.onPairingApproved',
          'params': {
            'deviceId': peerDeviceId,
            'approvedAt': approvePayload['approvedAt'],
          },
        });

        final record = await trustStore.getPeer(peerDeviceId);
        if (record?.state == TrustState.pairingPending) {
          _startTimeoutTimer(peerDeviceId, clearOutbound: false);
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
        _localApprovals.remove(peerDeviceId);
        _remoteApprovals.remove(peerDeviceId);
        _completionSent.remove(peerDeviceId);
        final record = await trustStore.getPeer(peerDeviceId);
        if (record?.state == TrustState.pairingPending) {
          await trustStore.transitionState(
            peerDeviceId,
            TrustState.pairingPending,
            TrustState.discovered,
          );
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

        final receivedDisplayName = completePayload['displayName'];
        if (receivedDisplayName is String &&
            receivedDisplayName.trim().isNotEmpty) {
          await trustStore.updateDisplayName(
            peerDeviceId,
            receivedDisplayName.trim(),
          );
        }

        if (record.state == TrustState.pairingPending &&
            _localApprovals.contains(peerDeviceId) &&
            _remoteApprovals.contains(peerDeviceId)) {
          _cancelTimeoutTimer(peerDeviceId);
          _outboundPairings.remove(peerDeviceId);
          _localApprovals.remove(peerDeviceId);
          _remoteApprovals.remove(peerDeviceId);
          _completionSent.remove(peerDeviceId);
          final now = DateTime.now().toUtc();
          await trustStore.transitionState(
            peerDeviceId,
            TrustState.pairingPending,
            TrustState.trusted,
            pairedAt: now,
          );
          sessionManager.updateTrustState(peerDeviceId, TrustState.trusted);
          await onPeerTrusted?.call(peerDeviceId);
          onIpcEvent({
            'jsonrpc': '2.0',
            'method': 'rift.onPairingComplete',
            'params': {
              'deviceId': peerDeviceId,
              'fingerprint': _deriveFingerprint(record.certDer),
              'persistedAt': now.toIso8601String(),
            },
          });
        }
        break;

      case 'trust.remove':
        final payload = msg.payload['payload'];
        if (payload is! Map<String, dynamic> ||
            payload['removedDeviceId'] is! String ||
            payload['reason'] is! String ||
            payload['removedAt'] is! String ||
            payload.containsKey('fingerprint')) {
          sessionManager.disconnectPeer(peerDeviceId);
          return;
        }

        final removedDeviceId = payload['removedDeviceId'] as String;
        if (removedDeviceId != identityManager.deviceId) {
          RiftLog.warn(
            '[Pairing] Ignoring trust.remove from $peerDeviceId targeting $removedDeviceId',
          );
          return;
        }

        final record = await trustStore.getPeer(peerDeviceId);
        if (record == null || record.state != TrustState.trusted) {
          RiftLog.warn(
            '[Pairing] Ignoring trust.remove from non-trusted peer $peerDeviceId',
          );
          sessionManager.disconnectPeer(peerDeviceId);
          return;
        }

        await trustStore.deletePeer(peerDeviceId);
        sessionManager.disconnectPeer(peerDeviceId);
        onIpcEvent({
          'jsonrpc': '2.0',
          'method': 'rift.onTrustChanged',
          'params': {
            'deviceId': peerDeviceId,
            'previousState': TrustState.trusted.toJson(),
            'newState': 'removed',
            'reason': payload['reason'],
          },
        });
        break;
    }
  }

  Future<void> _ensurePeerInTrustStore(
    String peerDeviceId,
    Uint8List? certDer,
  ) async {
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
      // Trusted and blocked peers keep their pinned certificate until an
      // explicit local action changes trust.
      if (record.state == TrustState.trusted ||
          record.state == TrustState.blocked) {
        return;
      }

      if (record.state == TrustState.revoked) {
        await trustStore.deletePeer(peerDeviceId);
        final replacement = PeerRecord(
          deviceId: peerDeviceId,
          displayName: record.displayName,
          certDer: certDer,
          state: TrustState.discovered,
          pairedAt: null,
          updatedAt: DateTime.now().toUtc(),
        );
        await trustStore.upsertPeer(replacement);
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

  Future<void> _sendPairingCompleteIfReady(
    String peerDeviceId,
    String persistedAt,
  ) async {
    if (!_localApprovals.contains(peerDeviceId) ||
        !_remoteApprovals.contains(peerDeviceId) ||
        !_completionSent.add(peerDeviceId)) {
      return;
    }

    try {
      await sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'pairing.complete',
        'sourceDeviceId': identityManager.deviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'trustedDeviceId': identityManager.deviceId,
          'persistedAt': persistedAt,
          'displayName': identityManager.displayName,
        },
      });
    } catch (_) {
      _completionSent.remove(peerDeviceId);
      rethrow;
    }
  }

  void _startTimeoutTimer(
    String peerDeviceId, {
    Duration? timeout,
    bool clearOutbound = true,
  }) {
    _cancelTimeoutTimer(peerDeviceId, clearOutbound: clearOutbound);
    _pairingTimeouts[peerDeviceId] = Timer(
      timeout ?? const Duration(seconds: _pairingTimeoutSeconds),
      () {
        _rejectPairing(peerDeviceId);
      },
    );
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
    _localApprovals.clear();
    _remoteApprovals.clear();
    _completionSent.clear();
    await _messageSubscription?.cancel();
    await _disconnectSubscription?.cancel();
  }

  String _deriveFingerprint(Uint8List certDer) {
    final peerPublicKey = RiftCertDecoder.extractEd25519PublicKeyFromDer(
      certDer,
    );
    final hash = sha256.convert(peerPublicKey).bytes;
    // Protocol Section 3.2: Base32(SHA-256(Ed25519)), uppercase, truncated to 32 chars, hyphenated groups of 4
    final base32Str = Base32Utils.encode(
      Uint8List.fromList(hash),
    ).toUpperCase().replaceAll('=', '');
    final truncated = base32Str.substring(0, 32);
    final hyphenated = truncated.replaceAllMapped(
      RegExp(r'.{4}'),
      (m) => '${m.group(0)}-',
    );
    return hyphenated.substring(0, 39); // Remove trailing hyphen
  }
}
