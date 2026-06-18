// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../core/rift_constants.dart';
import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../crypto/pop_manager.dart';

class ProtocolMessage {
  final String peerDeviceId;
  final Uint8List? peerCertDer;
  final Map<String, dynamic> payload;

  ProtocolMessage(this.peerDeviceId, this.peerCertDer, this.payload);
}

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
  final Future<bool> Function(String peerDeviceId)? _isPeerAllowed;
  final Map<String, SessionState> _sessions = {};
  final Set<String> _receivedSessionHello = {};
  StreamSubscription<TransportMessage>? _messageSubscription;
  StreamSubscription<String>? _disconnectSubscription;
  
  // Stream to broadcast established protocol messages to higher layers (PairingManager, etc.)
  final _messageController = StreamController<ProtocolMessage>.broadcast();
  Stream<ProtocolMessage> get onMessage => _messageController.stream;
  Stream<String> get onPeerDisconnected => _transport.onPeerDisconnected;

  // Risk-1 Mitigation (ADR-0002 fallback): dart:io SecureSocket does not expose
  // tls-exporter (RFC 9266) or tls-unique (RFC 5929). As the best available
  // platform-level substitute until dart:io supports it, we fallback to using
  // the envelope's UUIDv4 messageId to guarantee per-session uniqueness:
  //   channelBinding = SHA-256(messageId || localCertDer || peerCertDer)
  // TODO(Conformance): This is a protocol deviation. Wait for Dart support for RFC 9266.
  Uint8List _computeChannelBinding(Uint8List messageIdBytes, Uint8List peerCertDer) {
    final localCertDer = _identityManager.tlsCertificateDer;
    final input = Uint8List(messageIdBytes.length + localCertDer.length + peerCertDer.length);
    input.setRange(0, messageIdBytes.length, messageIdBytes);
    input.setRange(messageIdBytes.length, messageIdBytes.length + localCertDer.length, localCertDer);
    input.setRange(messageIdBytes.length + localCertDer.length, input.length, peerCertDer);
    return Uint8List.fromList(sha256.convert(input).bytes);
  }

  final Set<String> _requiredCapabilityNames = const {
    'clipboard.offer_fetch',
    'presence.basic',
    'operation.lifecycle',
    'security.event_log',
  };

  SessionManager(this._transport, this._identityManager, {Future<bool> Function(String peerDeviceId)? isPeerAllowed})
      : _isPeerAllowed = isPeerAllowed {
    _messageSubscription = _transport.onMessageReceived.listen(
      (msg) => _handleMessage(msg).catchError((Object e) {
        _transport.disconnect(msg.peerDeviceId);
      }),
    );
    // Prune stale session state on disconnect so a reconnecting peer isn't
    // rejected by the double-hello guard.
    _disconnectSubscription = _transport.onPeerDisconnected.listen((peerDeviceId) {
      _sessions.remove(peerDeviceId);
      _receivedSessionHello.remove(peerDeviceId);
    });
  }

  Future<void> sendSessionHello(String peerDeviceId) async {
    if (_sessions.containsKey(peerDeviceId)) {
      throw SessionException('Cannot send session.hello twice on the same connection for $peerDeviceId');
    }

    // Sign over the local cert DER — the verifier reconstructs the same input
    // from the peer's cert carried in the TLS handshake (spec §5.3).
    // Channel binding is computed from both certs (Risk-1 ADR-0002 fallback).
    final localCertDer = _identityManager.tlsCertificateDer;
    final peerCertDer = _transport.getPeerCert(peerDeviceId);
    if (peerCertDer == null) {
      throw SessionException('Cannot compute channel binding: peer cert not available for $peerDeviceId');
    }
    final messageIdStr = const Uuid().v4();
    final messageIdBytes = Uint8List.fromList(utf8.encode(messageIdStr));
    final channelBinding = _computeChannelBinding(messageIdBytes, peerCertDer);
    final proofHex = await _identityManager.generateIdentityProof(channelBinding, localCertDer);

    final payload = {
      'rift': RiftConstants.protocolVersion,
      'messageId': messageIdStr,
      'type': 'session.hello',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {
        'supportedVersions': [RiftConstants.protocolVersion],
        'deviceId': _identityManager.deviceId,
        'implementationId': RiftConstants.implementationId,
        'capabilities': RiftConstants.capabilities,
        'identityProof': proofHex,
      }
    };

    _sessions[peerDeviceId] = SessionState.handshaking;
    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }

  Future<void> sendMessage(String peerDeviceId, Map<String, dynamic> payload) async {
    if (_sessions[peerDeviceId] != SessionState.established) {
      throw SessionException('Cannot send message: Session not established with $peerDeviceId');
    }
    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }

  void disconnectPeer(String peerDeviceId) {
    _sessions.remove(peerDeviceId);
    _receivedSessionHello.remove(peerDeviceId);
    _transport.disconnect(peerDeviceId);
  }

  Future<void> _handleMessage(TransportMessage msg) async {
    late final Map<String, dynamic> jsonMap;
    try {
      final payloadStr = utf8.decode(msg.payload);
      final parsed = json.decode(payloadStr);
      if (parsed is! Map<String, dynamic>) {
        await _rejectSession(msg.peerDeviceId, 'MalformedMessage', 'Non-object message payload');
        return;
      }
      jsonMap = parsed;
    } on FormatException {
      await _rejectSession(msg.peerDeviceId, 'MalformedMessage', 'Invalid JSON payload');
      return;
    }

    final protocolVersion = jsonMap['rift'] as String?;
    if (protocolVersion != RiftConstants.protocolVersion) {
      await _rejectSession(msg.peerDeviceId, 'VersionMismatch', 'Unsupported protocol version');
      return;
    }

    final messageId = jsonMap['messageId'] as String?;
    if (messageId == null || messageId.isEmpty) {
      await _rejectSession(msg.peerDeviceId, 'MalformedMessage', 'Missing messageId');
      return;
    }

    final type = jsonMap['type'] as String?;
    if (type == null || type.isEmpty) {
      await _rejectSession(msg.peerDeviceId, 'MalformedMessage', 'Missing type');
      return;
    }
    final peerDeviceId = msg.peerDeviceId;
    final envelopeSourceDeviceId = jsonMap['sourceDeviceId'] as String?;
    final destinationDeviceId = jsonMap['destinationDeviceId'] as String?;
    final requiredExtensions = jsonMap['requiredExtensions'];

    if (destinationDeviceId != null && destinationDeviceId != _identityManager.deviceId) {
      await _rejectSession(peerDeviceId, 'Unauthorized', 'destinationDeviceId mismatch');
      return;
    }

    if (requiredExtensions != null) {
      if (requiredExtensions is! List) {
        await _rejectSession(peerDeviceId, 'ProtocolError', 'requiredExtensions must be an array');
        return;
      } else if (requiredExtensions.isNotEmpty) {
        await _rejectSession(peerDeviceId, 'ProtocolError', 'Unknown requiredExtensions');
        return;
      }
    }

    // ENVELOPE VALIDATION: §6 - device ID MUST match the authenticated TLS identity
    if (envelopeSourceDeviceId != peerDeviceId) {
      await _rejectSession(peerDeviceId, 'Unauthorized', 'sourceDeviceId mismatch with TLS identity');
      return;
    }

    if (type == 'session.hello') {
      await _handleSessionHello(msg, jsonMap);
    } else if (type == 'session.accept' || type == 'session.reject') {
      if (type == 'session.accept') {
        final payload = jsonMap['payload'] as Map<String, dynamic>?;
        final selectedVersion = payload?['selectedVersion'] as String?;
        final payloadDeviceId = payload?['deviceId'] as String?;
        final identityProofHex = payload?['identityProof'] as String?;
        final capabilities = payload?['capabilities'] as List?;
        final identityVerified = payload?['identityVerified'];
        final localCertDer = _identityManager.tlsCertificateDer;
        final peerCertDer = msg.peerCertDer!;

        if (selectedVersion != RiftConstants.protocolVersion) {
          await _rejectSession(peerDeviceId, 'VersionMismatch', 'Unexpected selectedVersion');
          return;
        }
        if (identityVerified != true) {
          await _rejectSession(peerDeviceId, 'ProtocolError', 'session.accept missing identityVerified: true');
          return;
        }
        if (payloadDeviceId != peerDeviceId) {
          await _rejectSession(peerDeviceId, 'Unauthorized', 'session.accept deviceId mismatch');
          return;
        }
        if (capabilities == null || !_hasRequiredCapabilities(capabilities)) {
          await _rejectSession(peerDeviceId, 'CapabilityUnavailable', 'Missing required capabilities');
          return;
        }
        if (identityProofHex == null || msg.peerEd25519Key == null || msg.peerCertDer == null) {
          await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing identity proof or cert');
          return;
        }

        final messageIdStr = jsonMap['messageId'] as String?;
        if (messageIdStr == null) {
          await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing messageId in envelope');
          return;
        }
        final messageIdBytes = Uint8List.fromList(utf8.encode(messageIdStr));

        final channelBindingForVerify = Uint8List(
            messageIdBytes.length + peerCertDer.length + localCertDer.length);
        channelBindingForVerify.setRange(0, messageIdBytes.length, messageIdBytes);
        channelBindingForVerify.setRange(
            messageIdBytes.length, messageIdBytes.length + peerCertDer.length, peerCertDer);
        channelBindingForVerify.setRange(
            messageIdBytes.length + peerCertDer.length, channelBindingForVerify.length, localCertDer);
        final channelBinding = Uint8List.fromList(
            sha256.convert(channelBindingForVerify).bytes);

        final isValidPoP = await PoPManager.verifyIdentityProof(
          identityProofHex,
          channelBinding,
          msg.peerEd25519Key!,
          peerCertDer,
        );

        if (!isValidPoP) {
          await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Invalid PoP Signature');
          throw SessionException('SecurityError: Invalid PoP Signature on session.accept');
        }

        _sessions[peerDeviceId] = SessionState.established;
        _transport.setPeerAuthenticated(peerDeviceId);
      } else {
        _sessions.remove(peerDeviceId);
        _transport.disconnect(peerDeviceId);
      }
    } else {
      if (_sessions[peerDeviceId] != SessionState.established) {
        await _rejectSession(peerDeviceId, 'Unauthorized', 'Session not established');
        return;
      }
      
      // Dispatch established messages to higher layers
      _messageController.add(ProtocolMessage(
        msg.peerDeviceId,
        msg.peerCertDer,
        jsonMap,
      ));
    }
  }

  Future<void> _rejectSession(String peerDeviceId, String failureReason, String message) async {
    final payload = {
      'rift': RiftConstants.protocolVersion,
      'type': 'session.reject',
      'messageId': const Uuid().v4(),
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

    // Risk 6 Mitigation: Prevent Double session.hello
    if (_receivedSessionHello.contains(peerDeviceId)) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'Double session.hello received');
      throw SessionException('ProtocolError: Double session.hello received from $peerDeviceId');
    }
    _receivedSessionHello.add(peerDeviceId);

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

    final supportedVersions = payload['supportedVersions'];
    final payloadDeviceId = payload['deviceId'] as String?;
    if (supportedVersions is! List || !supportedVersions.contains(RiftConstants.protocolVersion)) {
      await _rejectSession(peerDeviceId, 'VersionMismatch', 'No mutually supported protocol version');
      return;
    }
    if (payloadDeviceId != peerDeviceId) {
      await _rejectSession(peerDeviceId, 'Unauthorized', 'session.hello deviceId mismatch');
      return;
    }

    final implementationId = payload['implementationId'] as String?;
    if (implementationId == null || implementationId.isEmpty) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing implementationId');
      return;
    }

    if (payload['capabilities'] is! List) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing capabilities');
      return;
    }

    if (!await _isPeerAllowedForSession(peerDeviceId)) {
      await _rejectSession(peerDeviceId, 'Unauthorized', 'peer identity is blocked or revoked');
      throw SessionException('Unauthorized: peer identity is blocked or revoked');
    }

    // Risk 3 Mitigation: Strictly use the identity extracted from the TLS Certificate!
    // We absolutely IGNORE payload['deviceId'] for PoP verification.
    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing peer certificate context');
      throw SessionException('IdentityError: Missing peer certificate context');
    }

    final localCertDer = _identityManager.tlsCertificateDer;
    final peerCertDer = msg.peerCertDer!;

    final messageIdStr = jsonMap['messageId'] as String?;
    if (messageIdStr == null) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing messageId in envelope');
      return;
    }
    final messageIdBytes = Uint8List.fromList(utf8.encode(messageIdStr));

    final cbInput = Uint8List(messageIdBytes.length + peerCertDer.length + localCertDer.length);
    cbInput.setRange(0, messageIdBytes.length, messageIdBytes);
    cbInput.setRange(messageIdBytes.length, messageIdBytes.length + peerCertDer.length, peerCertDer);
    cbInput.setRange(messageIdBytes.length + peerCertDer.length, cbInput.length, localCertDer);
    final channelBindingHello = Uint8List.fromList(sha256.convert(cbInput).bytes);

    final isValidPoP = await PoPManager.verifyIdentityProof(
      identityProofHex,
      channelBindingHello,
      msg.peerEd25519Key!,
      peerCertDer,
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
    // Same cert-based channel binding used in sendSessionHello:
    // SHA-256(localCertDer || peerCertDer) — consistent with signing side.
    final localCertDer = _identityManager.tlsCertificateDer;
    final peerCertDer = msg.peerCertDer ?? _transport.getPeerCert(peerDeviceId);
    if (peerCertDer == null) {
      throw SessionException(
          'Cannot compute channel binding for session.accept: peer cert missing for $peerDeviceId');
    }
    final messageIdStr = const Uuid().v4();
    final messageIdBytes = Uint8List.fromList(utf8.encode(messageIdStr));
    final channelBinding = _computeChannelBinding(messageIdBytes, peerCertDer);
    final proofHex = await _identityManager.generateIdentityProof(channelBinding, localCertDer);

    final payload = {
      'rift': RiftConstants.protocolVersion,
      'type': 'session.accept',
      'messageId': messageIdStr,
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {
        'selectedVersion': RiftConstants.protocolVersion,
        'deviceId': _identityManager.deviceId,
        'identityVerified': true,
        'identityProof': proofHex,
        'capabilities': RiftConstants.capabilities,
      }
    };

    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }

  Future<bool> _isPeerAllowedForSession(String peerDeviceId) async {
    final resolver = _isPeerAllowed;
    if (resolver == null) return true;
    return await resolver(peerDeviceId);
  }

  bool _hasRequiredCapabilities(List capabilities) {
    final advertised = <String>{};
    for (final capability in capabilities) {
      if (capability is Map<String, dynamic>) {
        final name = capability['name'];
        if (name is String) {
          advertised.add(name);
        }
      }
    }
    return advertised.containsAll(_requiredCapabilityNames);
  }
  
  Future<void> dispose() async {
    await _messageSubscription?.cancel();
    await _disconnectSubscription?.cancel();
    await _messageController.close();
  }
}
