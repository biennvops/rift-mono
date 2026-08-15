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
  final Object? connectionToken;

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

  SessionContext({
    required this.peerDeviceId,
    required this.isInitiator,
    this.connectionToken,
  });

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
  final Set<SessionContext> _testingContexts = {};
  final Map<String, Completer<void>> _establishmentWaiters = {};
  final Map<String, Future<void>> _inboundMessageTails = {};
  late final StreamSubscription<TransportMessage> _transportMessageSubscription;
  StreamSubscription<String>? _transportDisconnectSubscription;
  StreamSubscription<TransportDisconnect>?
  _transportConnectionDisconnectSubscription;
  Future<void>? _disposeFuture;
  bool _disposed = false;

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
    String? bindingType, {
    TransportMessage? sourceMessage,
  }) async {
    if (bindingType == null) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing bindingType',
        sourceMessage: sourceMessage,
      );
      return null;
    }
    if (!_validBindingTypes.contains(bindingType)) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'AuthenticationFailed',
        'Unrecognized bindingType',
        sourceMessage: sourceMessage,
      );
      return null;
    }
    if (bindingType != 'app-nonce') {
      // Spec supports a tiered hierarchy (tls-exporter / tls-unique / app-nonce),
      // but dart:io SecureSocket does not expose TLS channel binding primitives.
      // This daemon can only *verify* PoP using Tier 3 (app-nonce).
      await _rejectHandshakeMessage(
        peerDeviceId,
        'AuthenticationFailed',
        'Unsupported bindingType on this platform: $bindingType (only app-nonce is supported by Dart daemon)',
        sourceMessage: sourceMessage,
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
    _transportMessageSubscription = _transport.onMessageReceived.listen(
      _queueInboundMessage,
    );
    final scopedTransport = _connectionScopedTransport;
    if (scopedTransport != null) {
      _transportConnectionDisconnectSubscription = scopedTransport
          .onConnectionDisconnected
          .listen(_handleConnectionDisconnected);
    } else {
      _transportDisconnectSubscription = _transport.onPeerDisconnected.listen(
        _handlePeerDisconnected,
      );
    }
  }

  ConnectionScopedTransport? get _connectionScopedTransport =>
      _transport is ConnectionScopedTransport
      ? _transport as ConnectionScopedTransport
      : null;

  void _queueInboundMessage(TransportMessage msg) {
    if (_disposed) return;
    final previous = _inboundMessageTails[msg.peerDeviceId];
    late final Future<void> next;
    next = (previous?.catchError((_) {}) ?? Future<void>.value())
        .then((_) => _handleMessage(msg))
        .catchError((Object error, StackTrace stackTrace) async {
          if (_disposed) return;
          RiftLog.error(
            '[Session] Unhandled exception in _handleMessage',
            error: error,
            stackTrace: stackTrace,
          );
          if (msg.pendingCandidate && _transport is PendingCandidateTransport) {
            await (_transport as PendingCandidateTransport)
                .rejectPendingCandidate(msg);
          } else {
            _disconnectMessageConnection(msg);
          }
        })
        .whenComplete(() {
          if (identical(_inboundMessageTails[msg.peerDeviceId], next)) {
            _inboundMessageTails.remove(msg.peerDeviceId);
          }
        });
    _inboundMessageTails[msg.peerDeviceId] = next;
  }

  void _handleConnectionDisconnected(TransportDisconnect event) {
    if (_disposed) return;
    final ctx = _sessions[event.peerDeviceId];
    if (ctx == null || !identical(ctx.connectionToken, event.connectionToken)) {
      RiftLog.debug(
        '[Session] Ignoring stale connection disconnect for '
        '${event.peerDeviceId} connection=${identityHashCode(event.connectionToken)}',
      );
      return;
    }
    _removeDisconnectedSession(event.peerDeviceId, ctx);
  }

  void _handlePeerDisconnected(String peerDeviceId) {
    if (_disposed) return;
    _removeDisconnectedSession(peerDeviceId, _sessions[peerDeviceId]);
  }

  void _removeDisconnectedSession(String peerDeviceId, SessionContext? ctx) {
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    _inboundMessageTails.remove(peerDeviceId);
    if (ctx == null || !identical(_sessions[peerDeviceId], ctx)) {
      return;
    }
    _sessions.remove(peerDeviceId);
    ctx.dispose();
    ctx.currentPresenceStatus = 'offline';
    if (!_presenceUpdateController.isClosed) {
      _presenceUpdateController.add(ctx);
    }
  }

  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  bool _isValidUuidV4(String value) => _uuidV4Pattern.hasMatch(value);

  Object? _currentConnectionToken(String peerDeviceId) =>
      _connectionScopedTransport?.currentConnectionToken(peerDeviceId);

  bool _isCurrentConnectionToken(String peerDeviceId, Object? connectionToken) {
    final scopedTransport = _connectionScopedTransport;
    if (scopedTransport == null) return true;
    return connectionToken != null &&
        scopedTransport.isCurrentConnection(peerDeviceId, connectionToken);
  }

  bool _isCurrentTransportMessage(TransportMessage msg) =>
      msg.pendingCandidate ||
      _isCurrentConnectionToken(msg.peerDeviceId, msg.connectionToken);

  bool _isCurrentContext(SessionContext ctx) =>
      !_disposed &&
      identical(_sessions[ctx.peerDeviceId], ctx) &&
      (_testingContexts.contains(ctx) ||
          _isCurrentConnectionToken(ctx.peerDeviceId, ctx.connectionToken));

  bool _messageBelongsToContext(TransportMessage msg, SessionContext ctx) =>
      _isCurrentContext(ctx) &&
      (_testingContexts.contains(ctx) ||
          _connectionScopedTransport == null ||
          identical(msg.connectionToken, ctx.connectionToken));

  void _disconnectMessageConnection(TransportMessage msg) {
    final scopedTransport = _connectionScopedTransport;
    if (scopedTransport != null && msg.connectionToken != null) {
      scopedTransport.disconnectConnection(
        msg.peerDeviceId,
        msg.connectionToken,
      );
      return;
    }
    _transport.disconnect(msg.peerDeviceId);
  }

  void _disconnectContextConnection(SessionContext ctx) {
    final scopedTransport = _connectionScopedTransport;
    if (scopedTransport != null) {
      if (ctx.connectionToken != null) {
        scopedTransport.disconnectConnection(
          ctx.peerDeviceId,
          ctx.connectionToken,
        );
      }
      return;
    }
    if (identical(_sessions[ctx.peerDeviceId], ctx)) {
      _transport.disconnect(ctx.peerDeviceId);
    }
  }

  void _logStaleWork(String operation, String peerDeviceId) {
    RiftLog.debug(
      '[Session] Ignoring stale $operation for $peerDeviceId; '
      'replacement connection/session is current',
    );
  }

  String _describeContext(SessionContext? ctx) {
    if (ctx == null) {
      return 'ctx=<null>';
    }
    return 'ctx={peer=${ctx.peerDeviceId}, '
        'connection=${ctx.connectionToken == null ? "none" : identityHashCode(ctx.connectionToken!)}, '
        'initiator=${ctx.isInitiator}, '
        'handshakeState=${ctx.handshakeState.name}, '
        'localHelloSent=${ctx.localHelloSent}, '
        'remoteHelloReceived=${ctx.remoteHelloReceived}, '
        'capabilityNegotiated=${ctx.capabilityNegotiated}, '
        'trustState=${ctx.trustState.toJson()}}';
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    await _transportMessageSubscription.cancel();
    await _transportDisconnectSubscription?.cancel();
    await _transportConnectionDisconnectSubscription?.cancel();
    final inboundWork = _inboundMessageTails.values.toList(growable: false);
    await Future.wait(inboundWork.map((work) => work.catchError((_) {})));

    final activeSessions = _sessions.values
        .where(
          (ctx) =>
              _isCurrentContext(ctx) &&
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

    _disposed = true;
    for (final waiter in _establishmentWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _establishmentWaiters.clear();
    for (final ctx in _sessions.values) {
      ctx.dispose();
    }
    _sessions.clear();
    _testingContexts.clear();
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
        !_isCurrentContext(ctx) ||
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

  SessionContext? getContext(String peerDeviceId) {
    final ctx = _sessions[peerDeviceId];
    return ctx != null && _isCurrentContext(ctx) ? ctx : null;
  }

  @visibleForTesting
  // Exposed solely for testing capability and presence logic without mocking real Ed25519 PoP crypto
  void injectContextForTesting(SessionContext ctx) {
    final previous = _sessions[ctx.peerDeviceId];
    if (previous != null) {
      _testingContexts.remove(previous);
    }
    _sessions[ctx.peerDeviceId] = ctx;
    _testingContexts.add(ctx);
  }

  /// The capability gate used by all other operations (e.g. clipboard, event log)
  void requireCapability(String peerDeviceId, String capabilityName) {
    final ctx = _sessions[peerDeviceId];
    if (ctx == null ||
        !_isCurrentContext(ctx) ||
        ctx.handshakeState != HandshakeState.established) {
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
    if (!_isCurrentContext(ctx) ||
        ctx.handshakeState != HandshakeState.established ||
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
      if (_isCurrentContext(existing)) {
        throw SessionException('Session already exists for $peerDeviceId');
      }
      if (identical(_sessions[peerDeviceId], existing)) {
        _sessions.remove(peerDeviceId);
        _testingContexts.remove(existing);
        _inboundMessageTails.remove(peerDeviceId);
        existing.dispose();
      }
    }
    final connectionToken = _currentConnectionToken(peerDeviceId);
    if (_connectionScopedTransport != null && connectionToken == null) {
      throw SessionException('Peer $peerDeviceId is not connected');
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
    if (!_isCurrentConnectionToken(peerDeviceId, connectionToken)) {
      _logStaleWork('session.hello', peerDeviceId);
      throw SessionException(
        'Connection replaced while starting session with $peerDeviceId',
      );
    }

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

    final ctx = SessionContext(
      peerDeviceId: peerDeviceId,
      isInitiator: true,
      connectionToken: connectionToken,
    );
    ctx.localHelloSent = true;
    final record = await _trustStore.getPeer(peerDeviceId);
    if (!_isCurrentConnectionToken(peerDeviceId, connectionToken) ||
        _sessions.containsKey(peerDeviceId)) {
      _logStaleWork('session.hello setup', peerDeviceId);
      throw SessionException(
        'Connection replaced while starting session with $peerDeviceId',
      );
    }
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
        _isCurrentContext(ctx) &&
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
        if (identical(_establishmentWaiters[peerDeviceId], waiter) &&
            ctx != null &&
            _isCurrentContext(ctx)) {
          disconnectPeer(peerDeviceId);
        }
        throw SessionException(
          'Timed out waiting for session establishment with $peerDeviceId',
        );
      },
    );

    final refreshed = _sessions[peerDeviceId];
    if (refreshed == null ||
        !_isCurrentContext(refreshed) ||
        refreshed.handshakeState != HandshakeState.established ||
        !refreshed.capabilityNegotiated) {
      throw SessionException('Session not established with $peerDeviceId');
    }
  }

  Future<void> _handleMessage(TransportMessage msg) async {
    if (_disposed) return;
    final peerDeviceId = msg.peerDeviceId;
    if (!_isCurrentTransportMessage(msg)) {
      _logStaleWork('incoming message', peerDeviceId);
      return;
    }
    late final Map<String, dynamic> jsonMap;
    try {
      final payloadStr = utf8.decode(msg.payload);
      final decoded = json.decode(payloadStr);
      if (decoded is! Map<String, dynamic>) {
        await _rejectHandshakeMessage(
          peerDeviceId,
          'MalformedMessage',
          'Top-level message must be a JSON object',
          sourceMessage: msg,
        );
        return;
      }
      jsonMap = decoded;
    } on FormatException {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Invalid JSON payload',
        sourceMessage: msg,
      );
      return;
    }

    final protocolVersion = jsonMap['rift'];
    if (protocolVersion is! String || protocolVersion != '0.1-draft') {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'VersionMismatch',
        'Unsupported protocol version',
        sourceMessage: msg,
      );
      return;
    }

    final messageId = jsonMap['messageId'];
    if (messageId is! String || !_isValidUuidV4(messageId)) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Missing or invalid messageId',
        sourceMessage: msg,
      );
      return;
    }

    final type = jsonMap['type'];
    if (type is! String) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Missing or invalid message type',
        sourceMessage: msg,
      );
      return;
    }
    RiftLog.debug('[Session] Received $type from $peerDeviceId');

    final requiredExtensions = jsonMap['requiredExtensions'];
    if (requiredExtensions != null && requiredExtensions is! List) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'ProtocolError',
        'requiredExtensions must be a list',
        sourceMessage: msg,
      );
      return;
    }
    if (requiredExtensions is List && requiredExtensions.isNotEmpty) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'ProtocolError',
        'Unknown requiredExtensions',
        sourceMessage: msg,
      );
      return;
    }

    final envelopeSourceDeviceId = jsonMap['sourceDeviceId'];
    if (envelopeSourceDeviceId is! String) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Missing or invalid sourceDeviceId',
        sourceMessage: msg,
      );
      return;
    }

    final destinationDeviceId = jsonMap['destinationDeviceId'];
    if (destinationDeviceId != null &&
        (destinationDeviceId is! String ||
            destinationDeviceId != _identityManager.deviceId)) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'Unauthorized',
        'destinationDeviceId mismatch',
        sourceMessage: msg,
      );
      return;
    }

    if (envelopeSourceDeviceId != peerDeviceId) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'Unauthorized',
        'sourceDeviceId mismatch with TLS identity',
        sourceMessage: msg,
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
      if (ctx == null ||
          !_messageBelongsToContext(msg, ctx) ||
          ctx.handshakeState != HandshakeState.established) {
        await _rejectSession(
          peerDeviceId,
          'Unauthorized',
          'Session not established',
          sourceMessage: msg,
          expectedContext: ctx,
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
          sourceMessage: msg,
          expectedContext: ctx,
        );
        return;
      } else if (type == 'device.metadata') {
        await _handleDeviceMetadata(ctx, msg, jsonMap);
      } else if (type == 'presence.update') {
        await _handlePresenceUpdate(ctx, msg, jsonMap);
      } else if (_messageBelongsToContext(msg, ctx) &&
          !_messageController.isClosed) {
        _messageController.add(
          ProtocolMessage(msg.peerDeviceId, msg.peerCertDer, jsonMap),
        );
      }
    }
  }

  Future<void> _rejectHandshakeMessage(
    String peerDeviceId,
    String failureReason,
    String message, {
    TransportMessage? sourceMessage,
  }) async {
    if (sourceMessage?.pendingCandidate == true &&
        _transport is PendingCandidateTransport) {
      RiftLog.warn(
        '[Session] Rejecting pending candidate from $peerDeviceId: '
        '$failureReason - $message',
      );
      await (_transport as PendingCandidateTransport).rejectPendingCandidate(
        sourceMessage!,
      );
      return;
    }
    await _rejectSession(
      peerDeviceId,
      failureReason,
      message,
      sourceMessage: sourceMessage,
    );
  }

  Future<void> _rejectSession(
    String peerDeviceId,
    String failureReason,
    String message, {
    TransportMessage? sourceMessage,
    SessionContext? expectedContext,
  }) async {
    final ctx = expectedContext ?? _sessions[peerDeviceId];
    final ownsConnection = sourceMessage != null
        ? _isCurrentTransportMessage(sourceMessage)
        : ctx != null && _isCurrentContext(ctx);
    if (!ownsConnection) {
      _logStaleWork('session rejection', peerDeviceId);
      if (sourceMessage != null) {
        _disconnectMessageConnection(sourceMessage);
      } else if (ctx != null) {
        _disconnectContextConnection(ctx);
      }
      return;
    }

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
      if (sourceMessage != null) {
        _disconnectMessageConnection(sourceMessage);
      } else if (ctx != null) {
        _disconnectContextConnection(ctx);
      }
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
    final contextUsesMessageConnection =
        ctx != null &&
        (_connectionScopedTransport == null ||
            identical(ctx.connectionToken, msg.connectionToken));
    if (!msg.pendingCandidate &&
        ctx != null &&
        contextUsesMessageConnection &&
        ctx.handshakeState != HandshakeState.established &&
        !(ctx.handshakeState == HandshakeState.handshaking &&
            ctx.isInitiator &&
            ctx.localHelloSent &&
            !ctx.remoteHelloReceived)) {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Double session.hello received',
        sourceMessage: msg,
        expectedContext: ctx,
      );
      throw SessionException(
        'ProtocolError: Double session.hello received from $peerDeviceId',
      );
    }
    if ((ctx == null ||
            !contextUsesMessageConnection ||
            msg.pendingCandidate) &&
        !await _isPeerAllowedForSession(peerDeviceId)) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'Unauthorized',
        'peer identity is blocked',
        sourceMessage: msg,
      );
      if (!msg.pendingCandidate) {
        throw SessionException('Unauthorized: peer identity is blocked');
      }
      return;
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Missing payload',
        sourceMessage: msg,
      );
      return;
    }

    final supportedVersions = payload['supportedVersions'];
    if (supportedVersions is! List ||
        !supportedVersions.whereType<String>().contains('0.1-draft')) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'VersionMismatch',
        'Missing or unsupported supportedVersions',
        sourceMessage: msg,
      );
      return;
    }

    final payloadDeviceId = payload['deviceId'] as String?;
    if (payloadDeviceId == null) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Missing payload.deviceId',
        sourceMessage: msg,
      );
      return;
    }
    if (payloadDeviceId != peerDeviceId) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'Unauthorized',
        'payload.deviceId mismatch with TLS identity',
        sourceMessage: msg,
      );
      return;
    }

    final identityProofHex = payload['identityProof'] as String?;
    if (identityProofHex == null) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing identityProof',
        sourceMessage: msg,
      );
      return;
    }

    final implementationId = payload['implementationId'] as String?;
    if (implementationId == null || implementationId.isEmpty) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Missing implementationId',
        sourceMessage: msg,
      );
      return;
    }

    final capabilities = payload['capabilities'];
    if (capabilities is! List) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Missing capabilities',
        sourceMessage: msg,
      );
      return;
    }
    if (capabilities.length > 64) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'ProtocolError',
        'Too many capabilities',
        sourceMessage: msg,
      );
      return;
    }

    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'AuthenticationFailed',
        'Missing peer certificate context',
        sourceMessage: msg,
      );
      if (!msg.pendingCandidate) {
        throw SessionException(
          'IdentityError: Missing peer certificate context',
        );
      }
      return;
    }

    final sessionNonceStr = payload['sessionNonce'] as String?;
    final bindingType = payload['bindingType'] as String?;

    final validatedBinding = await _validateBindingType(
      peerDeviceId,
      bindingType,
      sourceMessage: msg,
    );
    if (validatedBinding == null) return;

    if (sessionNonceStr == null) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'ProtocolError',
        'Missing sessionNonce',
        sourceMessage: msg,
      );
      return;
    }
    late final Uint8List peerNonce;
    try {
      peerNonce = base64.decode(sessionNonceStr);
    } on FormatException {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'MalformedMessage',
        'Invalid base64 in sessionNonce',
        sourceMessage: msg,
      );
      return;
    }
    if (peerNonce.length != 32) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'ProtocolError',
        'sessionNonce must be exactly 32 bytes',
        sourceMessage: msg,
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

    if (!msg.pendingCandidate && !_isCurrentTransportMessage(msg)) {
      _logStaleWork('session.hello verification', peerDeviceId);
      _disconnectMessageConnection(msg);
      return;
    }

    if (!isValidPoP) {
      await _rejectHandshakeMessage(
        peerDeviceId,
        'AuthenticationFailed',
        'Identity Misbinding / Invalid PoP Signature',
        sourceMessage: msg,
      );
      if (!msg.pendingCandidate) {
        throw SessionException(
          'SecurityError: Identity Misbinding / Invalid PoP Signature',
        );
      }
      return;
    }

    if (msg.pendingCandidate) {
      if (_transport is! PendingCandidateTransport) {
        throw StateError(
          'Transport marked a pending candidate without candidate controls',
        );
      }
      final promoted = await (_transport as PendingCandidateTransport)
          .promotePendingCandidate(msg);
      if (!promoted) {
        return;
      }
      if (!_isCurrentConnectionToken(peerDeviceId, msg.connectionToken)) {
        _logStaleWork('candidate promotion', peerDeviceId);
        _disconnectMessageConnection(msg);
        return;
      }
      ctx = _sessions[peerDeviceId];
    }

    final contextOwnsConnection =
        ctx != null &&
        (_connectionScopedTransport == null ||
            identical(ctx.connectionToken, msg.connectionToken));
    if (ctx == null || !contextOwnsConnection) {
      final previousContext = ctx;
      final replacement = SessionContext(
        peerDeviceId: peerDeviceId,
        isInitiator: false,
        connectionToken: msg.connectionToken,
      );
      final record = await _trustStore.getPeer(peerDeviceId);
      if (!_isCurrentConnectionToken(peerDeviceId, msg.connectionToken) ||
          !identical(_sessions[peerDeviceId], previousContext)) {
        _logStaleWork('responder session setup', peerDeviceId);
        _disconnectMessageConnection(msg);
        return;
      }
      replacement.trustState = record?.state ?? TrustState.discovered;
      previousContext?.dispose();
      _sessions[peerDeviceId] = replacement;
      ctx = replacement;
      RiftLog.info(
        '[Session] ${previousContext == null ? "Created" : "Replaced"} '
        'responder SessionContext for $peerDeviceId ${_describeContext(ctx)}',
      );
    } else if (ctx.handshakeState == HandshakeState.handshaking &&
        ctx.isInitiator &&
        ctx.localHelloSent &&
        !ctx.remoteHelloReceived) {
      RiftLog.debug(
        '[Session] Accepting simultaneous session.hello from $peerDeviceId while local hello is in flight.',
      );
    } else if (ctx.handshakeState == HandshakeState.established &&
        _connectionScopedTransport == null) {
      RiftLog.info(
        '[Session] Peer $peerDeviceId sent a verified fresh session.hello; '
        'rebuilding the session.',
      );
      final previousContext = ctx;
      final replacement = SessionContext(
        peerDeviceId: peerDeviceId,
        isInitiator: false,
        connectionToken: msg.connectionToken,
      );
      final record = await _trustStore.getPeer(peerDeviceId);
      if (!identical(_sessions[peerDeviceId], previousContext)) {
        _logStaleWork('responder session rebuild', peerDeviceId);
        return;
      }
      replacement.trustState = record?.state ?? TrustState.discovered;
      previousContext.dispose();
      _sessions[peerDeviceId] = replacement;
      ctx = replacement;
    } else {
      await _rejectSession(
        peerDeviceId,
        'ProtocolError',
        'Double session.hello received',
        sourceMessage: msg,
        expectedContext: ctx,
      );
      throw SessionException(
        'ProtocolError: Double session.hello received from $peerDeviceId',
      );
    }
    if (!_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('session.hello completion', peerDeviceId);
      _disconnectMessageConnection(msg);
      return;
    }
    ctx.remoteHelloReceived = true;
    RiftLog.debug(
      '[Session] Marked remoteHelloReceived for $peerDeviceId ${_describeContext(ctx)}',
    );

    RiftLog.debug(
      '[Session] Verified session.hello from $peerDeviceId; sending session.accept.',
    );
    await _sendSessionAccept(ctx);
    if (!_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('session.hello establishment', peerDeviceId);
      return;
    }

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
    if (!_isCurrentContext(ctx)) {
      _logStaleWork('session.accept send', ctx.peerDeviceId);
      return;
    }
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
    if (!_isCurrentContext(ctx)) {
      _logStaleWork('session.accept send', ctx.peerDeviceId);
      return;
    }

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
    Future<void> reject(String failureReason, String message) => _rejectSession(
      peerDeviceId,
      failureReason,
      message,
      sourceMessage: msg,
      expectedContext: ctx,
    );
    RiftLog.debug(
      '[Session] _handleSessionAccept entered for $peerDeviceId ${_describeContext(ctx)}',
    );

    if (ctx == null ||
        !_messageBelongsToContext(msg, ctx) ||
        ctx.handshakeState != HandshakeState.handshaking) {
      await reject('ProtocolError', 'Unexpected session.accept');
      return;
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await reject('MalformedMessage', 'Missing payload');
      return;
    }

    final identityVerified = payload['identityVerified'];
    if (identityVerified is! bool || !identityVerified) {
      await reject('ProtocolError', 'Missing or invalid identityVerified');
      return;
    }

    final selectedVersion = payload['selectedVersion'] as String?;
    if (selectedVersion != '0.1-draft') {
      await reject('VersionMismatch', 'Unexpected selectedVersion');
      return;
    }

    final payloadDeviceId = payload['deviceId'] as String?;
    if (payloadDeviceId != peerDeviceId) {
      await reject('Unauthorized', 'session.accept deviceId mismatch');
      return;
    }

    final capabilities = payload['capabilities'];
    if (capabilities is! List) {
      await reject('MalformedMessage', 'Missing capabilities');
      return;
    }
    if (capabilities.length > 64) {
      await reject('ProtocolError', 'Too many capabilities');
      return;
    }

    final bindingType = payload['bindingType'] as String?;
    final validatedBinding = await _validateBindingType(
      peerDeviceId,
      bindingType,
      sourceMessage: msg,
    );
    if (validatedBinding == null) return;

    final identityProofHex = payload['identityProof'] as String?;
    if (identityProofHex == null) {
      await reject('AuthenticationFailed', 'Missing identityProof');
      return;
    }

    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await reject('AuthenticationFailed', 'Missing peer certificate context');
      throw SessionException('IdentityError: Missing peer certificate context');
    }

    final sessionNonceStr = payload['sessionNonce'] as String?;
    if (sessionNonceStr == null) {
      await reject('ProtocolError', 'Missing sessionNonce');
      return;
    }
    late final Uint8List peerNonce;
    try {
      peerNonce = base64.decode(sessionNonceStr);
    } on FormatException {
      await reject('MalformedMessage', 'Invalid base64 in sessionNonce');
      return;
    }
    if (peerNonce.length != 32) {
      await reject('ProtocolError', 'sessionNonce must be exactly 32 bytes');
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

    if (!_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('session.accept verification', peerDeviceId);
      _disconnectMessageConnection(msg);
      return;
    }

    if (!isValidPoP) {
      await reject(
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
    final ctx = _sessions[peerDeviceId];
    if (ctx == null || !_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('session.reject', peerDeviceId);
      _disconnectMessageConnection(msg);
      return;
    }
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    _sessions.remove(peerDeviceId);
    ctx.dispose();
    _disconnectMessageConnection(msg);
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
    if (!_isCurrentContext(ctx)) {
      _logStaleWork('capability negotiation', ctx.peerDeviceId);
      return;
    }
    ctx.localAdvertisedCapabilities = _defaultCapabilities;
    RiftLog.debug(
      '[Session] Starting capability negotiation with ${ctx.peerDeviceId}',
    );

    ctx.capabilityNegotiationTimer?.cancel();
    ctx.capabilityNegotiationTimer = Timer(const Duration(seconds: 5), () {
      if (_isCurrentContext(ctx) &&
          shouldRejectCapabilityNegotiationTimeout(
            activeContext: _sessions[ctx.peerDeviceId],
            timedContext: ctx,
          )) {
        unawaited(
          _rejectSession(
            ctx.peerDeviceId,
            'Timeout',
            'Capability negotiation timed out',
            expectedContext: ctx,
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
          .catchError((Object error) {
            RiftLog.warn(
              '[Session] Capability advertise failed for '
              '${ctx.peerDeviceId}: $error',
            );
            _disconnectContextConnection(ctx);
          }),
    );
  }

  Future<void> _sendTrustedDeviceMetadata(
    SessionContext ctx, {
    bool requestPeerMetadata = true,
  }) async {
    if (!_isCurrentContext(ctx) || ctx.trustState != TrustState.trusted) {
      return;
    }
    final record = await _trustStore.getPeer(ctx.peerDeviceId);
    if (!_isCurrentContext(ctx) || record?.state != TrustState.trusted) {
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
    TransportMessage msg,
    Map<String, dynamic> jsonMap,
  ) async {
    Future<void> reject(String failureReason, String message) => _rejectSession(
      ctx.peerDeviceId,
      failureReason,
      message,
      sourceMessage: msg,
      expectedContext: ctx,
    );
    final payload = jsonMap['payload'];
    if (payload is! Map<String, dynamic>) {
      await reject('MalformedMessage', 'Missing device.metadata payload');
      return;
    }

    final rawDisplayName = payload['displayName'];
    final platform = payload['platform'];
    final requestPeerMetadata = payload['requestPeerMetadata'] ?? false;
    if (rawDisplayName is! String ||
        platform is! String ||
        requestPeerMetadata is! bool ||
        !_validPlatforms.contains(platform)) {
      await reject('ProtocolError', 'Invalid device.metadata payload');
      return;
    }

    final displayName = rawDisplayName.trim();
    if (displayName.isEmpty ||
        displayName.length > 128 ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(displayName)) {
      await reject('ProtocolError', 'Invalid device.metadata displayName');
      return;
    }

    if (ctx.trustState != TrustState.trusted ||
        !_messageBelongsToContext(msg, ctx)) {
      return;
    }

    await _persistTrustedDeviceMetadata(
      ctx.peerDeviceId,
      displayName,
      platform,
    );
    if (requestPeerMetadata && _messageBelongsToContext(msg, ctx)) {
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
    Future<void> reject(String failureReason, String message) => _rejectSession(
      ctx.peerDeviceId,
      failureReason,
      message,
      sourceMessage: msg,
      expectedContext: ctx,
    );
    if (!_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('capability.advertise', ctx.peerDeviceId);
      return;
    }
    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await reject(
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
        await reject('ProtocolError', 'Too many capabilities');
        return;
      }
      peerCaps = peerCapabilitiesList
          .map((e) => Capability.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      await reject('MalformedMessage', 'Invalid capability.advertise payload');
      return;
    } on TypeError {
      await reject('MalformedMessage', 'Invalid capability.advertise payload');
      return;
    } on ArgumentError {
      await reject('MalformedMessage', 'Invalid capability.advertise payload');
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
        await reject('ProtocolError', 'Capability constraint violation');
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
      if (!_messageBelongsToContext(msg, ctx)) {
        _logStaleWork('capability selection', ctx.peerDeviceId);
        return;
      }
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
    Future<void> reject(String failureReason, String message) => _rejectSession(
      ctx.peerDeviceId,
      failureReason,
      message,
      sourceMessage: msg,
      expectedContext: ctx,
    );
    if (!_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('capability.selected', ctx.peerDeviceId);
      return;
    }
    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await reject(
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
      await reject('MalformedMessage', 'Invalid capability.selected payload');
      return;
    } on TypeError {
      await reject('MalformedMessage', 'Invalid capability.selected payload');
      return;
    } on ArgumentError {
      await reject('MalformedMessage', 'Invalid capability.selected payload');
      return;
    }

    for (final cap in selectedCaps) {
      final localCap = ctx.localAdvertisedCapabilities
          .where((c) => c.name == cap.name)
          .firstOrNull;
      if (localCap == null || localCap.version < cap.version) {
        await reject(
          'ProtocolError',
          'Invalid capability selection: not advertised or version exceeds local',
        );
        return;
      }
      final peerCap = ctx.peerAdvertisedCapabilities
          .where((c) => c.name == cap.name)
          .firstOrNull;
      if (peerCap == null || peerCap.version < cap.version) {
        await reject(
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
    if (!_isCurrentContext(ctx) || ctx.capabilityNegotiated) {
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
    if (!_isCurrentContext(ctx)) return;
    final hasAllRequiredCaps = _requiredCapabilityNames.every(
      ctx.hasCapability,
    );
    if (ctx.trustState == TrustState.trusted && hasAllRequiredCaps) {
      final wasOnline = ctx.currentPresenceStatus == 'online';
      ctx.currentPresenceStatus = 'online';
      ctx.lastHeartbeatReceived = DateTime.now();
      if (!_presenceUpdateController.isClosed) {
        _presenceUpdateController.add(ctx);
      }
      if (!wasOnline && !_trustedSessionReadyController.isClosed) {
        _trustedSessionReadyController.add(ctx);
      }

      ctx.heartbeatTimer?.cancel();
      ctx.heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(_trySendHeartbeat(ctx));
      });

      _resetOfflineTimeout(ctx);
      unawaited(_trySendHeartbeat(ctx));
    }
  }

  Future<void> _trySendHeartbeat(SessionContext ctx) async {
    try {
      await _sendHeartbeat(ctx);
    } catch (error) {
      RiftLog.warn(
        '[Session] Heartbeat send failed for ${ctx.peerDeviceId}; '
        'retaining session until transport or liveness timeout closes it: $error',
      );
    }
  }

  void _resetOfflineTimeout(SessionContext ctx) {
    ctx.offlineTimeoutTimer?.cancel();
    ctx.offlineTimeoutTimer = Timer(const Duration(seconds: 45), () {
      if (!_isCurrentContext(ctx)) {
        return;
      }
      ctx.currentPresenceStatus = 'offline';
      if (!_presenceUpdateController.isClosed) {
        _presenceUpdateController.add(ctx);
      }
      _disconnectContextConnection(ctx);
    });
  }

  void updateTrustState(String peerDeviceId, TrustState newState) {
    final ctx = _sessions[peerDeviceId];
    if (ctx != null && _isCurrentContext(ctx)) {
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
        if (!_presenceUpdateController.isClosed) {
          _presenceUpdateController.add(ctx);
        }
      }
    }
  }

  Future<void> _sendHeartbeat(SessionContext ctx) =>
      _sendPresence(ctx, 'online');

  Future<void> _sendPresence(SessionContext ctx, String status) async {
    if (!_isCurrentContext(ctx) ||
        !isCurrentEstablishedContext(
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
    Future<void> reject(String failureReason, String message) => _rejectSession(
      ctx.peerDeviceId,
      failureReason,
      message,
      sourceMessage: msg,
      expectedContext: ctx,
    );
    _requireNegotiatedSessionCapability(ctx, 'presence.basic');
    final record = await _trustStore.getPeer(ctx.peerDeviceId);
    if (!_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('presence update', ctx.peerDeviceId);
      return;
    }
    if (record?.state != TrustState.trusted) {
      if (ctx.currentPresenceStatus != 'offline') {
        ctx.currentPresenceStatus = 'offline';
        if (!_presenceUpdateController.isClosed) {
          _presenceUpdateController.add(ctx);
        }
      }
      return;
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await reject('MalformedMessage', 'Missing payload in presence.update');
      return;
    }

    final status = payload['status'] as String?;
    if (status != 'online' && status != 'offline' && status != 'away') {
      await reject('ProtocolError', 'Invalid presence status');
      return;
    }

    List<String> reportedCaps;
    try {
      final caps = payload['capabilities'] as List<dynamic>? ?? [];
      if (caps.any((e) => e is! String)) {
        throw const FormatException('capabilities must be a list of strings');
      }
      reportedCaps = caps.cast<String>();
    } catch (_) {
      await reject(
        'MalformedMessage',
        'Invalid presence.update capabilities format',
      );
      return;
    }

    for (final cap in reportedCaps) {
      if (!ctx.hasCapability(cap)) {
        await reject(
          'ProtocolError',
          'Unnegotiated capability in presence update',
        );
        return;
      }
    }

    if (!_messageBelongsToContext(msg, ctx)) {
      _logStaleWork('presence update acceptance', ctx.peerDeviceId);
      return;
    }
    final receivedAt = DateTime.now();
    ctx.currentPresenceStatus = status!;
    ctx.lastHeartbeatReceived = receivedAt;
    _resetOfflineTimeout(ctx);
    if (!_presenceUpdateController.isClosed) {
      _presenceUpdateController.add(ctx);
    }

    try {
      await _trustStore.updateLastSeen(ctx.peerDeviceId, receivedAt);
    } catch (error) {
      RiftLog.warn(
        '[Session] Failed to persist last-seen for ${ctx.peerDeviceId}; '
        'in-memory liveness remains current: $error',
      );
    }
  }

  Future<bool> _isPeerAllowedForSession(String peerDeviceId) async {
    final resolver = peerAllowanceResolver;
    if (resolver == null) return true;
    return await resolver(peerDeviceId);
  }
}
