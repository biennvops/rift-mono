import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';

import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../crypto/pop_manager.dart';

enum SessionState {
  handshaking,
  established,
}

class SessionException implements Exception {
  final String message;
  SessionException(this.message);
  @override
  String toString() => 'SessionException: $message';
}

/// Orchestrates the Rift session lifecycle and enforces Risk 3 & Risk 6 mitigations.
class SessionManager {
  final Transport _transport;
  final IdentityManager _identityManager;
  final Map<String, SessionState> _sessions = {};
  
  // TODO(Blocker): Dart lacks tls-exporter, using a placeholder until ADR resolves Risk 1
  final Uint8List _dummyChannelBinding = Uint8List.fromList(List.generate(32, (_) => 0));

  SessionManager(this._transport, this._identityManager) {
    _transport.onMessageReceived.listen(
      (msg) => _handleMessage(msg).catchError((Object e) {
        _transport.disconnect(msg.peerDeviceId);
      }),
    );
    // Prune stale session state on disconnect so a reconnecting peer isn't
    // rejected by the double-hello guard.
    _transport.onPeerDisconnected.listen(_sessions.remove);
  }

  Future<void> sendSessionHello(String peerDeviceId) async {
    // Sign over the local cert DER — the verifier reconstructs the same input
    // from the peer's cert carried in the TLS handshake (spec §5.3).
    final localCertDer = _identityManager.tlsCertificateDer;
    final proofHex = await _identityManager.generateIdentityProof(_dummyChannelBinding, localCertDer);

    final payload = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'type': 'session.hello',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {
        'deviceId': _identityManager.deviceId,
        'fingerprint': _identityManager.getDeviceFingerprint().map((b) => b.toRadixString(16).padLeft(2, '0')).join(''),
        'identityProof': proofHex,
      }
    };

    _sessions[peerDeviceId] = SessionState.handshaking;
    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }

  Future<void> _handleMessage(TransportMessage msg) async {
    final payloadStr = utf8.decode(msg.payload);
    final jsonMap = json.decode(payloadStr) as Map<String, dynamic>;

    final type = jsonMap['type'] as String?;
    final peerDeviceId = msg.peerDeviceId;
    final envelopeSourceDeviceId = jsonMap['sourceDeviceId'] as String?;

    // ENVELOPE VALIDATION: §6 - device ID MUST match the authenticated TLS identity
    if (envelopeSourceDeviceId != peerDeviceId) {
      await _rejectSession(peerDeviceId, 'Unauthorized', 'sourceDeviceId mismatch with TLS identity');
      return;
    }

    if (type == 'session.hello') {
      await _handleSessionHello(msg, jsonMap);
    } else {
      if (_sessions[peerDeviceId] != SessionState.established) {
        await _rejectSession(peerDeviceId, 'Unauthorized', 'Session not established');
      }
    }
  }

  Future<void> _rejectSession(String peerDeviceId, String failureReason, String message) async {
    final payload = {
      'rift': '0.1-draft',
      'type': 'session.reject',
      'id': const Uuid().v4(),
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {
        'failureReason': failureReason,
        'message': message,
      }
    };
    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
    _transport.disconnect(peerDeviceId);
  }

  Future<void> _handleSessionHello(TransportMessage msg, Map<String, dynamic> jsonMap) async {
    final peerDeviceId = msg.peerDeviceId;
    final currentState = _sessions[peerDeviceId] ?? SessionState.handshaking;

    // Risk 6 Mitigation: Prevent Double session.hello
    if (currentState == SessionState.established) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'Double session.hello received');
      throw SessionException('ProtocolError: Double session.hello received from $peerDeviceId');
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing payload');
      return;
    }

    final identityProofHex = payload['identityProof'] as String?;
    if (identityProofHex == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing identityProof');
      return;
    }

    // Risk 3 Mitigation: Strictly use the identity extracted from the TLS Certificate!
    // We absolutely IGNORE payload['deviceId'] for PoP verification.
    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing peer certificate context');
      throw SessionException('IdentityError: Missing peer certificate context');
    }

    final isValidPoP = await PoPManager.verifyIdentityProof(
      identityProofHex,
      _dummyChannelBinding,
      msg.peerEd25519Key!,
      msg.peerCertDer!,
    );

    if (!isValidPoP) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Identity Misbinding / Invalid PoP Signature');
      throw SessionException('SecurityError: Identity Misbinding / Invalid PoP Signature');
    }

    _sessions[peerDeviceId] = SessionState.established;
    _transport.setPeerAuthenticated(peerDeviceId);
    await _sendSessionAccept(msg);
  }

  Future<void> _sendSessionAccept(TransportMessage msg) async {
    final peerDeviceId = msg.peerDeviceId;
    // Same PoP binding: sign over the local cert DER (spec §5.3).
    final localCertDer = _identityManager.tlsCertificateDer;
    final proofHex = await _identityManager.generateIdentityProof(_dummyChannelBinding, localCertDer);

    final payload = {
      'rift': '0.1-draft',
      'type': 'session.accept',
      'id': const Uuid().v4(),
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {
        'selectedVersion': '0.1-draft',
        'deviceId': _identityManager.deviceId,
        'identityVerified': true,
        'identityProof': proofHex,
        'capabilities': [
          { 'name': 'clipboard.offer_fetch', 'version': 1 },
          { 'name': 'presence.basic', 'version': 1 },
          { 'name': 'operation.lifecycle', 'version': 1 },
          { 'name': 'security.event_log', 'version': 1 }
        ]
      }
    };

    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }
}
