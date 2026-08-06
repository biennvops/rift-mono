import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../core/rift_log.dart';
import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../interfaces/trust_store.dart';
import '../crypto/pop_manager.dart';

enum HandshakeState { handshaking, established }

class ProtocolMessage {
  final String peerDeviceId;
  final Uint8List? peerCertDer;
  final Map<String, dynamic> payload;

  ProtocolMessage(this.peerDeviceId, this.peerCertDer, this.payload);
}

class SessionException implements Exception {
  final String message;
  SessionException(this.message);
  @override
  String toString() => 'SessionException: $message';
}

class Capability {
  final String name;
  final int version;
  final List<String> policyFlags;

  Capability({
    required this.name,
    required this.version,
    this.policyFlags = const [],
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    if (policyFlags.isNotEmpty) 'policyFlags': policyFlags,
  };

  factory Capability.fromJson(Map<String, dynamic> json) {
    if (json['name'] is! String || json['version'] is! int) {
      throw const FormatException('Invalid Capability format');
    }
    final rawFlags = json['policyFlags'] as List<dynamic>? ?? [];
    if (rawFlags.any((e) => e is! String)) {
      throw const FormatException('policyFlags must be a list of strings');
    }
    return Capability(
      name: json['name'] as String,
      version: json['version'] as int,
      policyFlags: rawFlags.cast<String>(),
    );
  }
}

class SessionContext {
  final String peerDeviceId;
  final bool isInitiator;

  HandshakeState handshakeState = HandshakeState.handshaking;
  TrustState trustState = TrustState.discovered;
  bool localHelloSent = false;
  bool remoteHelloReceived = false;
  bool capabilityNegotiated = false;

  List<Capability> localAdvertisedCapabilities = [];
  List<Capability> peerAdvertisedCapabilities = [];
  List<Capability> negotiatedCapabilities = [];

  DateTime? lastHeartbeatReceived;
  String currentPresenceStatus = 'offline';

  Timer? heartbeatTimer;
  Timer? offlineTimeoutTimer;
  Timer? capabilityNegotiationTimer;

  SessionContext({required this.peerDeviceId, required this.isInitiator});

  void dispose() {
    heartbeatTimer?.cancel();
    offlineTimeoutTimer?.cancel();
    capabilityNegotiationTimer?.cancel();
  }

  bool hasCapability(String name) {
    return negotiatedCapabilities.any((c) => c.name == name);
  }
}

/// Orchestrates the Rift session lifecycle, enforces capabilities, and tracks presence.
class SessionManager {
  final Transport _transport;
  final IdentityManager _identityManager;
  final TrustStore _trustStore;
  final Map<String, SessionContext> _sessions = {};
  final Map<String, Completer<void>> _establishmentWaiters = {};
  final Map<String, Future<void>> _inboundMessageTails = {};

  // Channel binding Tier 3 (spec §5.3.1 / ADR-0011): dart:io SecureSocket does
  // not expose tls-exporter (RFC 9266) or tls-unique (RFC 5929), so the Dart
  // daemon currently implements the normative app-nonce fallback:
  //   channelBinding = SHA-256(sessionNonce || localCertDer || peerCertDer)
  // This value is:
  //   • per-session unique (via the securely generated 32-byte sessionNonce),
  //   • tied to the specific cert pair (preventing cross-identity replay),
  //   • resistant to replay across distinct application sessions.
  // It does not cryptographically bind to the underlying TLS transcript; when
  // dart:io exposes tls-exporter, this implementation should upgrade to Tier 1.
  Uint8List _computeChannelBinding(
    Uint8List sessionNonce,
    Uint8List peerCertDer,
  ) {
    final localCertDer = _identityManager.tlsCertificateDer;
    final input = Uint8List(
      sessionNonce.length + localCertDer.length + peerCertDer.length,
    );
    input.setRange(0, sessionNonce.length, sessionNonce);
    input.setRange(
      sessionNonce.length,
      sessionNonce.length + localCertDer.length,
      localCertDer,
    );
    input.setRange(
      sessionNonce.length + localCertDer.length,
      input.length,
      peerCertDer,
    );
    return Uint8List.fromList(sha256.convert(input).bytes);
  }

  Uint8List _generateSessionNonce() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  }

  final Future<bool> Function(String)? peerAllowanceResolver;

  static const Set<String> _validPlatforms = {
    'android',
    'ios',
    'windows',
    'macos',
    'linux',
    'unknown',
  };

  static const Set<String> _validBindingTypes = {
    'tls-exporter',
    'tls-unique',
    'app-nonce',
  };

  Future<String?> _validateBindingType(
    String peerDeviceId,
    String? bindingType,
  ) async {
    if (bindingType == null) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing bindingType',
      );
      return null;
    }
    if (!_validBindingTypes.contains(bindingType)) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Unrecognized bindingType',
      );
      return null;
    }
    if (bindingType != 'app-nonce') {
      // Spec supports a tiered hierarchy (tls-exporter / tls-unique / app-nonce),
      // but dart:io SecureSocket does not expose TLS channel binding primitives.
      // This daemon can only *verify* PoP using Tier 3 (app-nonce).
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Unsupported bindingType on this platform: $bindingType (only app-nonce is supported by Dart daemon)',
      );
      return null;
    }
    return bindingType;
  }

  String _localPlatform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  Future<void> _persistTrustedDeviceMetadata(
    String peerDeviceId,
    String displayName,
    String platform,
  ) async {
    final existing = await _trustStore.getPeer(peerDeviceId);
    if (existing?.state != TrustState.trusted) {
      return;
    }

    await _trustStore.upsertPeer(
      PeerRecord(
        deviceId: existing!.deviceId,
        displayName: displayName,
        platform: platform,
        certDer: existing.certDer,
        state: existing.state,
        pairedAt: existing.pairedAt,
        updatedAt: DateTime.now().toUtc(),
        lastSeenAt: existing.lastSeenAt,
        trustedEndpoints: existing.trustedEndpoints,
      ),
    );
  }

  final Set<String> _requiredCapabilityNames = const {
    'clipboard.offer_fetch',
    'presence.basic',
    'operation.lifecycle',
    'security.event_log',
  };

  final _messageController = StreamController<ProtocolMessage>.broadcast();
  Stream<ProtocolMessage> get onMessage => _messageController.stream;
  Stream<String> get onPeerDisconnected => _transport.onPeerDisconnected;

  final _presenceUpdateController =
      StreamController<SessionContext>.broadcast();
  Stream<SessionContext> get onPresenceUpdate =>
      _presenceUpdateController.stream;

  final _trustedSessionReadyController =
      StreamController<SessionContext>.broadcast();
  Stream<SessionContext> get onTrustedSessionReady =>
      _trustedSessionReadyController.stream;

  static final List<Capability> _defaultCapabilities = [
    Capability(name: 'clipboard.offer_fetch', version: 1),
    Capability(name: 'device.status', version: 1),
    Capability(name: 'file.transfer', version: 1),
    Capability(name: 'media.playback', version: 1),
    Capability(name: 'notification.sync', version: 1),
    Capability(name: 'presence.basic', version: 1),
    Capability(name: 'operation.lifecycle', version: 1),
    Capability(name: 'security.event_log', version: 1),
  ];

  SessionManager(
    this._transport,
    this._identityManager,
    this._trustStore, {
    this.peerAllowanceResolver,
  }) {
    _transport.onMessageReceived.listen((msg) {
      final previous = _inboundMessageTails[msg.peerDeviceId];
      late final Future<void> next;
      next = (previous?.catchError((_) {}) ?? Future<void>.value())
          .then((_) => _handleMessage(msg))
          .catchError((Object e, StackTrace st) {
            RiftLog.error(
              '[Session] Unhandled exception in _handleMessage',
              error: e,
              stackTrace: st,
            );
            _transport.disconnect(msg.peerDeviceId);
          })
          .whenComplete(() {
            if (identical(_inboundMessageTails[msg.peerDeviceId], next)) {
              _inboundMessageTails.remove(msg.peerDeviceId);
            }
          });
      _inboundMessageTails[msg.peerDeviceId] = next;
    });
    _transport.onPeerDisconnected.listen((deviceId) {
      final waiter = _establishmentWaiters.remove(deviceId);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete();
      }
      _inboundMessageTails.remove(deviceId);
      final ctx = _sessions.remove(deviceId);
      if (ctx != null) {
        ctx.dispose();
        ctx.currentPresenceStatus = 'offline';
        _presenceUpdateController.add(ctx);
      }
    });
  }

  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  bool _isValidUuidV4(String value) => _uuidV4Pattern.hasMatch(value);

  String _describeContext(SessionContext? ctx) {
    if (ctx == null) {
      return 'ctx=<null>';
    }
    return 'ctx={peer=${ctx.peerDeviceId}, initiator=${ctx.isInitiator}, '
        'handshakeState=${ctx.handshakeState.name}, '
        'localHelloSent=${ctx.localHelloSent}, '
        'remoteHelloReceived=${ctx.remoteHelloReceived}, '
        'capabilityNegotiated=${ctx.capabilityNegotiated}, '
        'trustState=${ctx.trustState.toJson()}}';
  }

  Future<void> dispose() async {
    final activeSessions = _sessions.values
        .where(
          (ctx) =>
              ctx.handshakeState == HandshakeState.established &&
              ctx.capabilityNegotiated &&
              ctx.hasCapability('presence.basic'),
        )
        .toList();
    await Future.wait(
      activeSessions.map(
        (ctx) => _sendPresence(ctx, 'offline').catchError((_) {}),
      ),
    );

    for (final waiter in _establishmentWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _establishmentWaiters.clear();
    for (var ctx in _sessions.values) {
      ctx.dispose();
    }
    _sessions.clear();
    _inboundMessageTails.clear();
    await _trustedSessionReadyController.close();
    await _presenceUpdateController.close();
    await _messageController.close();
  }

  Future<void> sendMessage(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final ctx = _sessions[peerDeviceId];
    RiftLog.debug(
      '[Session] sendMessage type=${payload['type']} peerDeviceId=$peerDeviceId '
      '${_describeContext(ctx)}',
    );
    if (ctx == null ||
        ctx.handshakeState != HandshakeState.established ||
        !ctx.capabilityNegotiated) {
      throw SessionException(
        'Cannot send message: Session not established with $peerDeviceId',
      );
    }
    await _transport.sendMessage(
      peerDeviceId,
      Uint8List.fromList(utf8.encode(json.encode(payload))),
    );
    RiftLog.debug(
      '[Session] sendMessage completed type=${payload['type']} peerDeviceId=$peerDeviceId',
    );
  }

  Future<void> sendPeerError(
    String peerDeviceId, {
    required String failureReason,
    String? refMessageId,
    required String message,
  }) => sendMessage(peerDeviceId, {
    'rift': '0.1-draft',
    'messageId': const Uuid().v4(),
    'type': 'error',
    'sourceDeviceId': _identityManager.deviceId,
    'destinationDeviceId': peerDeviceId,
    'payload': {
      'failureReason': failureReason,
      'refMessageId': ?refMessageId,
      'message': message,
    },
  });

  void disconnectPeer(String peerDeviceId) {
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    _sessions[peerDeviceId]?.dispose();
    _sessions.remove(peerDeviceId);
    _transport.disconnect(peerDeviceId);
  }

  SessionContext? getContext(String peerDeviceId) => _sessions[peerDeviceId];

  @visibleForTesting
  // Exposed solely for testing capability and presence logic without mocking real Ed25519 PoP crypto
  void injectContextForTesting(SessionContext ctx) {
    _sessions[ctx.peerDeviceId] = ctx;
  }

  /// The capability gate used by all other operations (e.g. clipboard, event log)
  void requireCapability(String peerDeviceId, String capabilityName) {
    final ctx = _sessions[peerDeviceId];
    if (ctx == null || ctx.handshakeState != HandshakeState.established) {
      throw SessionException('Unauthorized: Session not established');
    }
    if (ctx.trustState != TrustState.trusted) {
      throw SessionException('Unauthorized: Peer not trusted');
    }
    if (!ctx.hasCapability(capabilityName)) {
      throw SessionException(
        'CapabilityUnavailable: $capabilityName not negotiated',
      );
    }
  }

  void _requireNegotiatedSessionCapability(
    SessionContext ctx,
    String capabilityName,
  ) {
    if (ctx.handshakeState != HandshakeState.established ||
        !ctx.capabilityNegotiated) {
      throw SessionException('Unauthorized: Session not established');
    }
    if (!ctx.hasCapability(capabilityName)) {
      throw SessionException(
        'CapabilityUnavailable: $capabilityName not negotiated',
      );
    }
  }

  Future<void> sendSessionHello(String peerDeviceId) async {
    final existing = _sessions[peerDeviceId];
    if (existing != null) {
      throw SessionException('Session already exists for $peerDeviceId');
    }
    final localCertDer = _identityManager.tlsCertificateDer;
    final peerCertDer = _transport.getPeerCert(peerDeviceId);
    if (peerCertDer == null) {
      throw SessionException(
        'Cannot compute channel binding: peer cert not available',
      );
    }
    final sessionNonce = _generateSessionNonce();
    final channelBinding = _computeChannelBinding(sessionNonce, peerCertDer);
    final proofHex = await _identityManager.generateIdentityProof(
      channelBinding,
      localCertDer,
    );

    final payload = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'session.hello',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {
        'deviceId': _identityManager.deviceId,
        'supportedVersions': ['0.1-draft'],
        'implementationId': 'riftd-dart/0.1.0',
        'capabilities': _defaultCapabilities.map((c) => c.toJson()).toList(),
        'bindingType': 'app-nonce',
        'sessionNonce': base64.encode(sessionNonce),
        'identityProof': proofHex,
      },
    };

    final ctx = SessionContext(peerDeviceId: peerDeviceId, isInitiator: true);
    ctx.localHelloSent = true;
    final record = await _trustStore.getPeer(peerDeviceId);
    ctx.trustState = record?.state ?? TrustState.discovered;
    _sessions[peerDeviceId] = ctx;
    _establishmentWaiters.putIfAbsent(peerDeviceId, Completer<void>.new);
    RiftLog.debug('[Session] Sending session.hello to $peerDeviceId');

    await _transport.sendMessage(
      peerDeviceId,
      Uint8List.fromList(utf8.encode(json.encode(payload))),
    );
  }

  Future<void> waitForSessionEstablished(
    String peerDeviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final ctx = _sessions[peerDeviceId];
    if (ctx != null &&
        ctx.handshakeState == HandshakeState.established &&
        ctx.capabilityNegotiated) {
      return;
    }

    final waiter = _establishmentWaiters.putIfAbsent(
      peerDeviceId,
      Completer<void>.new,
    );
    RiftLog.debug(
      '[Session] Waiting for session establishment with $peerDeviceId',
    );
    await waiter.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_establishmentWaiters[peerDeviceId], waiter)) {
          disconnectPeer(peerDeviceId);
        }
        throw SessionException(
          'Timed out waiting for session establishment with $peerDeviceId',
        );
      },
    );

    final refreshed = _sessions[peerDeviceId];
    if (refreshed == null ||
        refreshed.handshakeState != HandshakeState.established ||
        !refreshed.capabilityNegotiated) {
      throw SessionException('Session not established with $peerDeviceId');
    }
  }

  Future<void> _handleMessage(TransportMessage msg) async {
    final peerDeviceId = msg.peerDeviceId;
    late final Map<String, dynamic> jsonMap;
    try {
      final payloadStr = utf8.decode(msg.payload);
      final decoded = json.decode(payloadStr);
      if (decoded is! Map<String, dynamic>) {
        await _rejectSession(
          peerDeviceId,
          'MalformedMessage',
          'Top-level message must be a JSON object',
        );
        return;
      }
      jsonMap = decoded;
    } on FormatException {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Invalid JSON payload',
      );
      return;
    }

    final protocolVersion = jsonMap['rift'];
    if (protocolVersion is! String || protocolVersion != '0.1-draft') {
      await _rejectSession(
        peerDeviceId,
        'VersionMismatch',
        'Unsupported protocol version',
      );
      return;
    }

    final messageId = jsonMap['messageId'];
    if (messageId is! String || !_isValidUuidV4(messageId)) {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Missing or invalid messageId',
      );
      return;
    }

    final type = jsonMap['type'];
    if (type is! String) {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Missing or invalid message type',
      );
      return;
    }
    RiftLog.debug('[Session] Received $type from $peerDeviceId');

    final requiredExtensions = jsonMap['requiredExtensions'];
    if (requiredExtensions != null && requiredExtensions is! List) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'requiredExtensions must be a list',
      );
      return;
    }
    if (requiredExtensions is List && requiredExtensions.isNotEmpty) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Unknown requiredExtensions',
      );
      return;
    }

    final envelopeSourceDeviceId = jsonMap['sourceDeviceId'];
    if (envelopeSourceDeviceId is! String) {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Missing or invalid sourceDeviceId',
      );
      return;
    }

    final destinationDeviceId = jsonMap['destinationDeviceId'];
    if (destinationDeviceId != null &&
        (destinationDeviceId is! String ||
            destinationDeviceId != _identityManager.deviceId)) {
      await _rejectSession(
        peerDeviceId,
        'Unauthorized',
        'destinationDeviceId mismatch',
      );
      return;
    }

    if (envelopeSourceDeviceId != peerDeviceId) {
      await _rejectSession(
        peerDeviceId,
        'Unauthorized',
        'sourceDeviceId mismatch with TLS identity',
      );
      return;
    }

    if (type == 'session.hello') {
      await _handleSessionHello(msg, jsonMap);
    } else if (type == 'session.accept') {
      await _handleSessionAccept(msg, jsonMap);
    } else if (type == 'session.reject') {
      await _handleSessionReject(msg, jsonMap);
    } else {
      final ctx = _sessions[peerDeviceId];
      if (ctx == null || ctx.handshakeState != HandshakeState.established) {
        await _rejectSession(
          peerDeviceId,
          'Unauthorized',
          'Session not established',
        );
        return;
      }

      if (type == 'capability.advertise') {
        await _handleCapabilityAdvertise(ctx, msg, jsonMap);
      } else if (type == 'capability.selected') {
        await _handleCapabilitySelected(ctx, msg, jsonMap);
      } else if (!ctx.capabilityNegotiated) {
        await _rejectSession(
          peerDeviceId,
          'ProtocolError',
          'Capability negotiation not complete',
        );
        return;
      } else if (type == 'device.metadata') {
        await _handleDeviceMetadata(ctx, jsonMap);
      } else if (type == 'presence.update') {
        await _handlePresenceUpdate(ctx, msg, jsonMap);
      } else {
        _messageController.add(
          ProtocolMessage(msg.peerDeviceId, msg.peerCertDer, jsonMap),
        );
      }
    }
  }

  Future<void> _rejectSession(
    String peerDeviceId,
    String failureReason,
    String message,
  ) async {
    final ctx = _sessions[peerDeviceId];
    RiftLog.warn(
      '[Session] Rejecting session with $peerDeviceId: $failureReason - $message '
      '${_describeContext(ctx)}',
    );
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    final payload = {
      'rift': '0.1-draft',
      'type': 'session.reject',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {'failureReason': failureReason, 'message': message},
    };
    try {
      await _transport.sendMessage(
        peerDeviceId,
        Uint8List.fromList(utf8.encode(json.encode(payload))),
      );
    } on StateError {
      // The peer socket may already be gone; rejection is best-effort.
    } finally {
      _transport.disconnect(peerDeviceId);
    }
  }

  Future<void> _handleSessionHello(
    TransportMessage msg,
    Map<String, dynamic> jsonMap,
  ) async {
    final peerDeviceId = msg.peerDeviceId;
    var ctx = _sessions[peerDeviceId];
    RiftLog.debug(
      '[Session] _handleSessionHello entered for $peerDeviceId ${_describeContext(ctx)}',
    );
    if (ctx == null) {
      if (!await _isPeerAllowedForSession(peerDeviceId)) {
        await _rejectSession(
          peerDeviceId,
          'Unauthorized',
          'peer identity is blocked',
        );
        throw SessionException('Unauthorized: peer identity is blocked');
      }
      ctx = SessionContext(peerDeviceId: peerDeviceId, isInitiator: false);
      final record = await _trustStore.getPeer(peerDeviceId);
      ctx.trustState = record?.state ?? TrustState.discovered;
      _sessions[peerDeviceId] = ctx;
      RiftLog.info(
        '[Session] Created responder SessionContext for $peerDeviceId ${_describeContext(ctx)}',
      );
    } else if (ctx.handshakeState == HandshakeState.handshaking &&
        ctx.isInitiator &&
        ctx.localHelloSent &&
        !ctx.remoteHelloReceived) {
      RiftLog.debug(
        '[Session] Accepting simultaneous session.hello from $peerDeviceId while local hello is in flight.',
      );
    } else if (ctx.handshakeState == HandshakeState.established) {
      // The peer would not send a fresh session.hello if it still considered
      // the session alive; mobile apps get killed/suspended without a clean
      // TCP close, leaving us with a zombie established context. Treat the
      // hello as a peer restart and rebuild the session on the connection it
      // arrived over. Do not touch the transport: the hello came in on the
      // transport's current (live) connection for this peer.
      RiftLog.info(
        '[Session] Peer $peerDeviceId sent session.hello over an established '
        'session; assuming peer restart and rebuilding session.',
      );
      ctx.dispose();
      ctx = SessionContext(peerDeviceId: peerDeviceId, isInitiator: false);
      final record = await _trustStore.getPeer(peerDeviceId);
      ctx.trustState = record?.state ?? TrustState.discovered;
      _sessions[peerDeviceId] = ctx;
    } else {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Double session.hello received',
      );
      throw SessionException(
        'ProtocolError: Double session.hello received from $peerDeviceId',
      );
    }
    ctx.remoteHelloReceived = true;
    RiftLog.debug(
      '[Session] Marked remoteHelloReceived for $peerDeviceId ${_describeContext(ctx)}',
    );

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing payload');
      return;
    }

    final supportedVersions = payload['supportedVersions'];
    if (supportedVersions is! List ||
        !supportedVersions.whereType<String>().contains('0.1-draft')) {
      await _rejectSession(
        peerDeviceId,
        'VersionMismatch',
        'Missing or unsupported supportedVersions',
      );
      return;
    }

    final payloadDeviceId = payload['deviceId'] as String?;
    if (payloadDeviceId == null) {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Missing payload.deviceId',
      );
      return;
    }
    if (payloadDeviceId != peerDeviceId) {
      await _rejectSession(
        peerDeviceId,
        'Unauthorized',
        'payload.deviceId mismatch with TLS identity',
      );
      return;
    }

    final identityProofHex = payload['identityProof'] as String?;
    if (identityProofHex == null) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing identityProof',
      );
      return;
    }

    final implementationId = payload['implementationId'] as String?;
    if (implementationId == null || implementationId.isEmpty) {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Missing implementationId',
      );
      return;
    }

    final capabilities = payload['capabilities'];
    if (capabilities is! List) {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Missing capabilities',
      );
      return;
    }
    if (capabilities.length > 64) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Too many capabilities',
      );
      return;
    }

    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing peer certificate context',
      );
      throw SessionException('IdentityError: Missing peer certificate context');
    }

    final sessionNonceStr = payload['sessionNonce'] as String?;
    final bindingType = payload['bindingType'] as String?;

    final validatedBinding = await _validateBindingType(
      peerDeviceId,
      bindingType,
    );
    if (validatedBinding == null) return;

    if (sessionNonceStr == null) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Missing sessionNonce',
      );
      return;
    }
    late final Uint8List peerNonce;
    try {
      peerNonce = base64.decode(sessionNonceStr);
    } on FormatException {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Invalid base64 in sessionNonce',
      );
      return;
    }
    if (peerNonce.length != 32) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'sessionNonce must be exactly 32 bytes',
      );
      return;
    }
    final localCertDer = _identityManager.tlsCertificateDer;
    final cbInput = Uint8List(
      peerNonce.length + msg.peerCertDer!.length + localCertDer.length,
    );
    cbInput.setRange(0, peerNonce.length, peerNonce);
    cbInput.setRange(
      peerNonce.length,
      peerNonce.length + msg.peerCertDer!.length,
      msg.peerCertDer!,
    );
    cbInput.setRange(
      peerNonce.length + msg.peerCertDer!.length,
      cbInput.length,
      localCertDer,
    );
    final channelBinding = Uint8List.fromList(sha256.convert(cbInput).bytes);

    final isValidPoP = await PoPManager.verifyIdentityProof(
      identityProofHex,
      channelBinding,
      msg.peerEd25519Key!,
      msg.peerCertDer!,
    );

    if (!isValidPoP) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Identity Misbinding / Invalid PoP Signature',
      );
      throw SessionException(
        'SecurityError: Identity Misbinding / Invalid PoP Signature',
      );
    }

    RiftLog.debug(
      '[Session] Verified session.hello from $peerDeviceId; sending session.accept.',
    );
    await _sendSessionAccept(ctx);

    // Sequential (unidirectional) handshake: if we are the responder (no local hello in flight),
    // the peer may not send a second session.accept back. Move to established immediately and
    // begin capability negotiation.
    if (!ctx.isInitiator && ctx.handshakeState == HandshakeState.handshaking) {
      RiftLog.debug(
        '[Session] Responder handshake established with $peerDeviceId; starting capability negotiation.',
      );
      ctx.handshakeState = HandshakeState.established;
      _transport.setPeerAuthenticated(peerDeviceId);
      await _startCapabilityNegotiation(ctx);
    }
  }

  Future<void> _sendSessionAccept(SessionContext ctx) async {
    final localCertDer = _identityManager.tlsCertificateDer;
    final peerCertDer = _transport.getPeerCert(ctx.peerDeviceId);
    if (peerCertDer == null) {
      throw SessionException(
        'Cannot compute channel binding: peer cert not available',
      );
    }
    final sessionNonce = _generateSessionNonce();
    final channelBinding = _computeChannelBinding(sessionNonce, peerCertDer);
    final proofHex = await _identityManager.generateIdentityProof(
      channelBinding,
      localCertDer,
    );

    final payload = {
      'rift': '0.1-draft',
      'type': 'session.accept',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': ctx.peerDeviceId,
      'payload': {
        'selectedVersion': '0.1-draft',
        'deviceId': _identityManager.deviceId,
        'identityVerified': true,
        'bindingType': 'app-nonce',
        'sessionNonce': base64.encode(sessionNonce),
        'identityProof': proofHex,
        'capabilities': _defaultCapabilities.map((c) => c.toJson()).toList(),
      },
    };

    await _transport.sendMessage(
      ctx.peerDeviceId,
      Uint8List.fromList(utf8.encode(json.encode(payload))),
    );
  }

  Future<void> _handleSessionAccept(
    TransportMessage msg,
    Map<String, dynamic> jsonMap,
  ) async {
    final peerDeviceId = msg.peerDeviceId;
    final ctx = _sessions[peerDeviceId];
    RiftLog.debug(
      '[Session] _handleSessionAccept entered for $peerDeviceId ${_describeContext(ctx)}',
    );

    if (ctx == null || ctx.handshakeState != HandshakeState.handshaking) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Unexpected session.accept',
      );
      return;
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing payload');
      return;
    }

    final identityVerified = payload['identityVerified'];
    if (identityVerified is! bool || !identityVerified) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Missing or invalid identityVerified',
      );
      return;
    }

    final selectedVersion = payload['selectedVersion'] as String?;
    if (selectedVersion != '0.1-draft') {
      await _rejectSession(
        peerDeviceId,
        'VersionMismatch',
        'Unexpected selectedVersion',
      );
      return;
    }

    final payloadDeviceId = payload['deviceId'] as String?;
    if (payloadDeviceId != peerDeviceId) {
      await _rejectSession(
        peerDeviceId,
        'Unauthorized',
        'session.accept deviceId mismatch',
      );
      return;
    }

    final capabilities = payload['capabilities'];
    if (capabilities is! List) {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Missing capabilities',
      );
      return;
    }
    if (capabilities.length > 64) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Too many capabilities',
      );
      return;
    }

    final bindingType = payload['bindingType'] as String?;
    final validatedBinding = await _validateBindingType(
      peerDeviceId,
      bindingType,
    );
    if (validatedBinding == null) return;

    final identityProofHex = payload['identityProof'] as String?;
    if (identityProofHex == null) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing identityProof',
      );
      return;
    }

    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing peer certificate context',
      );
      throw SessionException('IdentityError: Missing peer certificate context');
    }

    final sessionNonceStr = payload['sessionNonce'] as String?;
    if (sessionNonceStr == null) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Missing sessionNonce',
      );
      return;
    }
    late final Uint8List peerNonce;
    try {
      peerNonce = base64.decode(sessionNonceStr);
    } on FormatException {
      await _rejectSession(
        peerDeviceId,
        'MalformedMessage',
        'Invalid base64 in sessionNonce',
      );
      return;
    }
    if (peerNonce.length != 32) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'sessionNonce must be exactly 32 bytes',
      );
      return;
    }
    final localCertDer = _identityManager.tlsCertificateDer;
    final cbInput = Uint8List(
      peerNonce.length + msg.peerCertDer!.length + localCertDer.length,
    );
    cbInput.setRange(0, peerNonce.length, peerNonce);
    cbInput.setRange(
      peerNonce.length,
      peerNonce.length + msg.peerCertDer!.length,
      msg.peerCertDer!,
    );
    cbInput.setRange(
      peerNonce.length + msg.peerCertDer!.length,
      cbInput.length,
      localCertDer,
    );
    final channelBinding = Uint8List.fromList(sha256.convert(cbInput).bytes);

    final isValidPoP = await PoPManager.verifyIdentityProof(
      identityProofHex,
      channelBinding,
      msg.peerEd25519Key!,
      msg.peerCertDer!,
    );

    if (!isValidPoP) {
      await _rejectSession(
        peerDeviceId,
        'AuthenticationFailed',
        'Identity Misbinding / Invalid PoP Signature',
      );
      throw SessionException(
        'SecurityError: Identity Misbinding / Invalid PoP Signature',
      );
    }

    RiftLog.debug(
      '[Session] Verified session.accept from $peerDeviceId; marking established and starting capability negotiation.',
    );
    ctx.handshakeState = HandshakeState.established;
    RiftLog.debug(
      '[Session] Marked established after session.accept for $peerDeviceId ${_describeContext(ctx)}',
    );
    _transport.setPeerAuthenticated(peerDeviceId);
    await _startCapabilityNegotiation(ctx);
  }

  Future<void> _handleSessionReject(
    TransportMessage msg,
    Map<String, dynamic> jsonMap,
  ) async {
    final peerDeviceId = msg.peerDeviceId;
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    final ctx = _sessions.remove(peerDeviceId);
    ctx?.dispose();
    _transport.disconnect(peerDeviceId);
  }

  @visibleForTesting
  static bool shouldRejectCapabilityNegotiationTimeout({
    required SessionContext? activeContext,
    required SessionContext timedContext,
  }) =>
      identical(activeContext, timedContext) &&
      !timedContext.capabilityNegotiated;

  @visibleForTesting
  static bool isCurrentEstablishedContext({
    required SessionContext? activeContext,
    required SessionContext candidateContext,
  }) =>
      identical(activeContext, candidateContext) &&
      candidateContext.handshakeState == HandshakeState.established &&
      candidateContext.capabilityNegotiated;

  Future<void> _startCapabilityNegotiation(SessionContext ctx) async {
    ctx.localAdvertisedCapabilities = _defaultCapabilities;
    RiftLog.debug(
      '[Session] Starting capability negotiation with ${ctx.peerDeviceId}',
    );

    ctx.capabilityNegotiationTimer?.cancel();
    ctx.capabilityNegotiationTimer = Timer(const Duration(seconds: 5), () {
      if (shouldRejectCapabilityNegotiationTimeout(
        activeContext: _sessions[ctx.peerDeviceId],
        timedContext: ctx,
      )) {
        unawaited(
          _rejectSession(
            ctx.peerDeviceId,
            'Timeout',
            'Capability negotiation timed out',
          ).catchError((Object error) {
            RiftLog.warn(
              '[Session] Best-effort negotiation-timeout reject failed for '
              '${ctx.peerDeviceId}: $error',
            );
          }),
        );
      }
    });

    final payload = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'capability.advertise',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': ctx.peerDeviceId,
      'payload': {
        'capabilities': ctx.localAdvertisedCapabilities
            .map((c) => c.toJson())
            .toList(),
      },
    };
    unawaited(
      _transport
          .sendMessage(
            ctx.peerDeviceId,
            Uint8List.fromList(utf8.encode(json.encode(payload))),
          )
          .catchError((_) {
            _transport.disconnect(ctx.peerDeviceId);
          }),
    );
  }

  Future<void> _sendTrustedDeviceMetadata(
    SessionContext ctx, {
    bool requestPeerMetadata = true,
  }) async {
    if (!isCurrentEstablishedContext(
          activeContext: _sessions[ctx.peerDeviceId],
          candidateContext: ctx,
        ) ||
        ctx.trustState != TrustState.trusted ||
        (await _trustStore.getPeer(ctx.peerDeviceId))?.state !=
            TrustState.trusted) {
      return;
    }

    final message = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'device.metadata',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': ctx.peerDeviceId,
      'payload': {
        'displayName': _identityManager.displayName,
        'platform': _localPlatform(),
        'requestPeerMetadata': requestPeerMetadata,
      },
    };
    await _transport.sendMessage(
      ctx.peerDeviceId,
      Uint8List.fromList(utf8.encode(json.encode(message))),
    );
  }

  Future<void> _handleDeviceMetadata(
    SessionContext ctx,
    Map<String, dynamic> jsonMap,
  ) async {
    final payload = jsonMap['payload'];
    if (payload is! Map<String, dynamic>) {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Missing device.metadata payload',
      );
      return;
    }

    final rawDisplayName = payload['displayName'];
    final platform = payload['platform'];
    final requestPeerMetadata = payload['requestPeerMetadata'] ?? false;
    if (rawDisplayName is! String ||
        platform is! String ||
        requestPeerMetadata is! bool ||
        !_validPlatforms.contains(platform)) {
      await _rejectSession(
        ctx.peerDeviceId,
        'ProtocolError',
        'Invalid device.metadata payload',
      );
      return;
    }

    final displayName = rawDisplayName.trim();
    if (displayName.isEmpty ||
        displayName.length > 128 ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(displayName)) {
      await _rejectSession(
        ctx.peerDeviceId,
        'ProtocolError',
        'Invalid device.metadata displayName',
      );
      return;
    }

    if (ctx.trustState != TrustState.trusted) {
      return;
    }

    await _persistTrustedDeviceMetadata(
      ctx.peerDeviceId,
      displayName,
      platform,
    );
    if (requestPeerMetadata) {
      await _sendTrustedDeviceMetadata(ctx, requestPeerMetadata: false);
    }
  }

  Future<void> _syncTrustedDeviceMetadata(SessionContext ctx) =>
      _sendTrustedDeviceMetadata(ctx);

  void _scheduleTrustedDeviceMetadataSync(SessionContext ctx) {
    unawaited(
      _syncTrustedDeviceMetadata(ctx).catchError((Object error) {
        RiftLog.warn(
          '[Session] Trusted device metadata sync failed for '
          '${ctx.peerDeviceId}: $error',
        );
      }),
    );
  }

  Future<void> _handleCapabilityAdvertise(
    SessionContext ctx,
    TransportMessage msg,
    Map<String, dynamic> jsonMap,
  ) async {
    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Missing payload in capability.advertise',
      );
      return;
    }

    List<Capability> peerCaps;
    try {
      final peerCapabilitiesList =
          payload['capabilities'] as List<dynamic>? ?? [];
      if (peerCapabilitiesList.length > 64) {
        await _rejectSession(
          ctx.peerDeviceId,
          'ProtocolError',
          'Too many capabilities',
        );
        return;
      }
      peerCaps = peerCapabilitiesList
          .map((e) => Capability.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Invalid capability.advertise payload',
      );
      return;
    } on TypeError {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Invalid capability.advertise payload',
      );
      return;
    } on ArgumentError {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Invalid capability.advertise payload',
      );
      return;
    }

    ctx.peerAdvertisedCapabilities = peerCaps;
    RiftLog.debug(
      '[Session] Received capability.advertise from ${ctx.peerDeviceId}',
    );
    for (final c in ctx.peerAdvertisedCapabilities) {
      if (c.name.length > 128 ||
          c.policyFlags.length > 16 ||
          c.policyFlags.any((f) => f.length > 128)) {
        await _rejectSession(
          ctx.peerDeviceId,
          'ProtocolError',
          'Capability constraint violation',
        );
        return;
      }
    }

    if (ctx.isInitiator) {
      final selectedCaps = <Capability>[];
      for (final localCap in ctx.localAdvertisedCapabilities) {
        final peerCap = ctx.peerAdvertisedCapabilities
            .where((c) => c.name == localCap.name)
            .firstOrNull;
        if (peerCap != null) {
          final selectedVersion = localCap.version < peerCap.version
              ? localCap.version
              : peerCap.version;
          if (selectedVersion >= 1) {
            selectedCaps.add(
              Capability(name: localCap.name, version: selectedVersion),
            );
          }
        }
      }

      ctx.negotiatedCapabilities = selectedCaps;
      ctx.capabilityNegotiationTimer?.cancel();

      final reply = {
        'rift': '0.1-draft',
        'id': const Uuid().v4(),
        'messageId': const Uuid().v4(),
        'type': 'capability.selected',
        'sourceDeviceId': _identityManager.deviceId,
        'destinationDeviceId': ctx.peerDeviceId,
        'payload': {
          'selectedCapabilities': selectedCaps.map((c) => c.toJson()).toList(),
        },
      };
      await _transport.sendMessage(
        ctx.peerDeviceId,
        Uint8List.fromList(utf8.encode(json.encode(reply))),
      );
      RiftLog.debug(
        '[Session] Sent capability.selected to ${ctx.peerDeviceId}',
      );
      _markSessionReady(ctx, 'initiator selected capabilities');

      _startHeartbeatIfTrusted(ctx);
    }
  }

  Future<void> _handleCapabilitySelected(
    SessionContext ctx,
    TransportMessage msg,
    Map<String, dynamic> jsonMap,
  ) async {
    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Missing payload in capability.selected',
      );
      return;
    }

    List<Capability> selectedCaps;
    try {
      final selectedCapsList =
          payload['selectedCapabilities'] as List<dynamic>? ?? [];
      selectedCaps = selectedCapsList
          .map((e) => Capability.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Invalid capability.selected payload',
      );
      return;
    } on TypeError {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Invalid capability.selected payload',
      );
      return;
    } on ArgumentError {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Invalid capability.selected payload',
      );
      return;
    }

    for (final cap in selectedCaps) {
      final localCap = ctx.localAdvertisedCapabilities
          .where((c) => c.name == cap.name)
          .firstOrNull;
      if (localCap == null || localCap.version < cap.version) {
        await _rejectSession(
          ctx.peerDeviceId,
          'ProtocolError',
          'Invalid capability selection: not advertised or version exceeds local',
        );
        return;
      }
      final peerCap = ctx.peerAdvertisedCapabilities
          .where((c) => c.name == cap.name)
          .firstOrNull;
      if (peerCap == null || peerCap.version < cap.version) {
        await _rejectSession(
          ctx.peerDeviceId,
          'ProtocolError',
          'Invalid capability selection: not advertised by peer',
        );
        return;
      }
    }

    ctx.negotiatedCapabilities = selectedCaps;
    ctx.capabilityNegotiationTimer?.cancel();
    RiftLog.debug(
      '[Session] Capability negotiation completed with ${ctx.peerDeviceId}',
    );
    _markSessionReady(ctx, 'responder received selected capabilities');
    _startHeartbeatIfTrusted(ctx);
  }

  void _markSessionReady(SessionContext ctx, String reason) {
    if (ctx.capabilityNegotiated) {
      return;
    }
    ctx.capabilityNegotiated = true;
    if (ctx.trustState == TrustState.trusted) {
      _scheduleTrustedDeviceMetadataSync(ctx);
    }
    final waiter = _establishmentWaiters.remove(ctx.peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      RiftLog.info(
        '[Session] Session fully established with ${ctx.peerDeviceId}: $reason',
      );
      waiter.complete();
    }
  }

  void _startHeartbeatIfTrusted(SessionContext ctx) {
    final hasAllRequiredCaps = _requiredCapabilityNames.every(
      ctx.hasCapability,
    );
    if (ctx.trustState == TrustState.trusted && hasAllRequiredCaps) {
      final wasOnline = ctx.currentPresenceStatus == 'online';
      ctx.currentPresenceStatus = 'online';
      ctx.lastHeartbeatReceived = DateTime.now();
      _presenceUpdateController.add(ctx);
      if (!wasOnline) {
        _trustedSessionReadyController.add(ctx);
      }

      ctx.heartbeatTimer?.cancel();
      ctx.heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(
          _sendHeartbeat(ctx).catchError((Object error, StackTrace stackTrace) {
            if (identical(_sessions[ctx.peerDeviceId], ctx)) {
              _transport.disconnect(ctx.peerDeviceId);
            }
          }),
        );
      });

      _resetOfflineTimeout(ctx);
      unawaited(
        _sendHeartbeat(ctx).catchError((Object error, StackTrace stackTrace) {
          if (identical(_sessions[ctx.peerDeviceId], ctx)) {
            _transport.disconnect(ctx.peerDeviceId);
          }
        }),
      );
    }
  }

  void _resetOfflineTimeout(SessionContext ctx) {
    ctx.offlineTimeoutTimer?.cancel();
    ctx.offlineTimeoutTimer = Timer(const Duration(seconds: 45), () {
      if (!identical(_sessions[ctx.peerDeviceId], ctx)) {
        return;
      }
      ctx.currentPresenceStatus = 'offline';
      _presenceUpdateController.add(ctx);
      _transport.disconnect(ctx.peerDeviceId);
    });
  }

  void updateTrustState(String peerDeviceId, TrustState newState) {
    final ctx = _sessions[peerDeviceId];
    if (ctx != null) {
      final wasTrusted = ctx.trustState == TrustState.trusted;
      ctx.trustState = newState;
      if (!wasTrusted && newState == TrustState.trusted) {
        // If capability negotiation has already completed, start the heartbeat.
        // Otherwise, _startHeartbeatIfTrusted will be called at the end of negotiation.
        if (ctx.capabilityNegotiated) {
          _startHeartbeatIfTrusted(ctx);
          _scheduleTrustedDeviceMetadataSync(ctx);
        }
      } else if (wasTrusted && newState != TrustState.trusted) {
        ctx.heartbeatTimer?.cancel();
        ctx.currentPresenceStatus = 'offline';
        _presenceUpdateController.add(ctx);
      }
    }
  }

  Future<void> _sendHeartbeat(SessionContext ctx) =>
      _sendPresence(ctx, 'online');

  Future<void> _sendPresence(SessionContext ctx, String status) async {
    if (!isCurrentEstablishedContext(
      activeContext: _sessions[ctx.peerDeviceId],
      candidateContext: ctx,
    )) {
      return;
    }

    final payload = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'presence.update',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': ctx.peerDeviceId,
      'payload': {
        'status': status,
        'capabilities': ctx.negotiatedCapabilities.map((c) => c.name).toList(),
      },
    };
    await _transport.sendMessage(
      ctx.peerDeviceId,
      Uint8List.fromList(utf8.encode(json.encode(payload))),
    );
  }

  Future<void> _handlePresenceUpdate(
    SessionContext ctx,
    TransportMessage msg,
    Map<String, dynamic> jsonMap,
  ) async {
    _requireNegotiatedSessionCapability(ctx, 'presence.basic');
    final record = await _trustStore.getPeer(ctx.peerDeviceId);
    if (record?.state != TrustState.trusted) {
      if (ctx.currentPresenceStatus != 'offline') {
        ctx.currentPresenceStatus = 'offline';
        _presenceUpdateController.add(ctx);
      }
      return;
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Missing payload in presence.update',
      );
      return;
    }

    final status = payload['status'] as String?;
    if (status != 'online' && status != 'offline' && status != 'away') {
      await _rejectSession(
        ctx.peerDeviceId,
        'ProtocolError',
        'Invalid presence status',
      );
      return;
    }

    List<String> reportedCaps;
    try {
      final caps = payload['capabilities'] as List<dynamic>? ?? [];
      if (caps.any((e) => e is! String)) {
        throw const FormatException('capabilities must be a list of strings');
      }
      reportedCaps = caps.cast<String>();
    } catch (e) {
      await _rejectSession(
        ctx.peerDeviceId,
        'MalformedMessage',
        'Invalid presence.update capabilities format',
      );
      return;
    }

    for (final cap in reportedCaps) {
      if (!ctx.hasCapability(cap)) {
        await _rejectSession(
          ctx.peerDeviceId,
          'ProtocolError',
          'Unnegotiated capability in presence update',
        );
        return;
      }
    }

    ctx.currentPresenceStatus = status!;
    ctx.lastHeartbeatReceived = DateTime.now();
    await _trustStore.updateLastSeen(
      ctx.peerDeviceId,
      ctx.lastHeartbeatReceived!,
    );
    _resetOfflineTimeout(ctx);

    _presenceUpdateController.add(ctx);
  }

  Future<bool> _isPeerAllowedForSession(String peerDeviceId) async {
    final resolver = peerAllowanceResolver;
    if (resolver == null) return true;
    return await resolver(peerDeviceId);
  }
}
