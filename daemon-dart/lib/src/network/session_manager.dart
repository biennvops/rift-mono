import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

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

  Capability({required this.name, required this.version, this.policyFlags = const []});

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
  
  
  Uint8List _computeChannelBinding(Uint8List sessionNonce, Uint8List peerCertDer) {
    final localCertDer = _identityManager.tlsCertificateDer;
    final input = Uint8List(sessionNonce.length + localCertDer.length + peerCertDer.length);
    input.setRange(0, sessionNonce.length, sessionNonce);
    input.setRange(sessionNonce.length, sessionNonce.length + localCertDer.length, localCertDer);
    input.setRange(sessionNonce.length + localCertDer.length, input.length, peerCertDer);
    return Uint8List.fromList(sha256.convert(input).bytes);
  }

  Uint8List _generateSessionNonce() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  }

  final Future<bool> Function(String)? peerAllowanceResolver;

  static const Set<String> _validBindingTypes = {'tls-exporter', 'tls-unique', 'app-nonce'};

  Future<String?> _validateBindingType(String peerDeviceId, String? bindingType) async {
    if (bindingType == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing bindingType');
      return null;
    }
    if (!_validBindingTypes.contains(bindingType)) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Unrecognized bindingType');
      return null;
    }
    if (bindingType != 'app-nonce') {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed',
          'Dart daemon only supports app-nonce bindingType');
      return null;
    }
    return bindingType;
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

  final _presenceUpdateController = StreamController<SessionContext>.broadcast();
  Stream<SessionContext> get onPresenceUpdate => _presenceUpdateController.stream;

  static final List<Capability> _defaultCapabilities = [
    Capability(name: 'clipboard.offer_fetch', version: 1),
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
    _transport.onMessageReceived.listen(
      (msg) => _handleMessage(msg).catchError((Object e) {
        _transport.disconnect(msg.peerDeviceId);
      }),
    );
    _transport.onPeerDisconnected.listen((deviceId) {
      final waiter = _establishmentWaiters.remove(deviceId);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete();
      }
      final ctx = _sessions.remove(deviceId);
      if (ctx != null) {
        ctx.dispose();
        ctx.currentPresenceStatus = 'offline';
        _presenceUpdateController.add(ctx);
      }
    });
  }

  Future<void> dispose() async {
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
    await _presenceUpdateController.close();
    await _messageController.close();
  }


  Future<void> sendMessage(String peerDeviceId, Map<String, dynamic> payload) async {
    final ctx = _sessions[peerDeviceId];
    if (ctx == null || ctx.handshakeState != HandshakeState.established) {
      throw SessionException('Cannot send message: Session not established with $peerDeviceId');
    }
    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }

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
      throw SessionException('CapabilityUnavailable: $capabilityName not negotiated');
    }
  }

  Future<void> sendSessionHello(String peerDeviceId) async {
    final existing = _sessions[peerDeviceId];
    if (existing != null) {
      throw SessionException('Session already exists for $peerDeviceId');
    }
    final localCertDer = _identityManager.tlsCertificateDer;
    final peerCertDer = _transport.getPeerCert(peerDeviceId);
    if (peerCertDer == null) throw SessionException('Cannot compute channel binding: peer cert not available');
    final sessionNonce = _generateSessionNonce();
    final channelBinding = _computeChannelBinding(sessionNonce, peerCertDer);
    final proofHex = await _identityManager.generateIdentityProof(channelBinding, localCertDer);

    final payload = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'messageId': const Uuid().v4(),
      'type': 'session.hello',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': peerDeviceId,
      'payload': {
        'deviceId': _identityManager.deviceId,
        'fingerprint': _identityManager.getDeviceFingerprint().map((b) => b.toRadixString(16).padLeft(2, '0')).join(''),
        'supportedVersions': ['0.1-draft'],
        'sessionNonce': base64.encode(sessionNonce),
        'identityProof': proofHex,
      }
    };

    final ctx = SessionContext(peerDeviceId: peerDeviceId, isInitiator: true);
    final record = await _trustStore.getPeer(peerDeviceId);
    ctx.trustState = record?.state ?? TrustState.discovered;
    _sessions[peerDeviceId] = ctx;
    _establishmentWaiters.putIfAbsent(peerDeviceId, Completer<void>.new);
    
    await _transport.sendMessage(peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }

  Future<void> waitForSessionEstablished(
    String peerDeviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final ctx = _sessions[peerDeviceId];
    if (ctx != null && ctx.handshakeState == HandshakeState.established) {
      return;
    }

    final waiter = _establishmentWaiters.putIfAbsent(peerDeviceId, Completer<void>.new);
    await waiter.future.timeout(
      timeout,
      onTimeout: () => throw SessionException(
        'Timed out waiting for session establishment with $peerDeviceId',
      ),
    );

    final refreshed = _sessions[peerDeviceId];
    if (refreshed == null || refreshed.handshakeState != HandshakeState.established) {
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
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Invalid JSON payload');
      return;
    }

    final type = jsonMap['type'];
    if (type is! String) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing or invalid message type');
      return;
    }

    final requiredExtensions = jsonMap['requiredExtensions'];
    if (requiredExtensions != null && requiredExtensions is! List) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'requiredExtensions must be a list');
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

    if (envelopeSourceDeviceId != peerDeviceId) {
      await _rejectSession(peerDeviceId, 'Unauthorized', 'sourceDeviceId mismatch with TLS identity');
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
        await _rejectSession(peerDeviceId, 'Unauthorized', 'Session not established');
        return;
      }
      
      if (type == 'capability.advertise') {
        await _handleCapabilityAdvertise(ctx, msg, jsonMap);
      } else if (type == 'capability.selected') {
        await _handleCapabilitySelected(ctx, msg, jsonMap);
            } else if (type == 'presence.update') {
        await _handlePresenceUpdate(ctx, msg, jsonMap);
      } else {
        _messageController.add(ProtocolMessage(msg.peerDeviceId, msg.peerCertDer, jsonMap));
      }
    }
  }

  Future<void> _rejectSession(String peerDeviceId, String failureReason, String message) async {
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
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
    var ctx = _sessions[peerDeviceId];
    if (ctx == null) {
      if (!await _isPeerAllowedForSession(peerDeviceId)) {
        await _rejectSession(peerDeviceId, 'Unauthorized', 'peer identity is blocked or revoked');
        throw SessionException('Unauthorized: peer identity is blocked or revoked');
      }
      ctx = SessionContext(peerDeviceId: peerDeviceId, isInitiator: false);
      final record = await _trustStore.getPeer(peerDeviceId);
      ctx.trustState = record?.state ?? TrustState.discovered;
      _sessions[peerDeviceId] = ctx;
    } else {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'Double session.hello received');
      throw SessionException('ProtocolError: Double session.hello received from $peerDeviceId');
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing payload');
      return;
    }

    final supportedVersions = payload['supportedVersions'];
    if (supportedVersions is! List ||
        !supportedVersions.whereType<String>().contains('0.1-draft')) {
      await _rejectSession(peerDeviceId, 'VersionMismatch', 'Missing or unsupported supportedVersions');
      return;
    }

    final payloadDeviceId = payload['deviceId'] as String?;
    if (payloadDeviceId == null) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing payload.deviceId');
      return;
    }
    if (payloadDeviceId != peerDeviceId) {
      await _rejectSession(peerDeviceId, 'Unauthorized', 'payload.deviceId mismatch with TLS identity');
      return;
    }

    final identityProofHex = payload['identityProof'] as String?;
    if (identityProofHex == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing identityProof');
      return;
    }

    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing peer certificate context');
      throw SessionException('IdentityError: Missing peer certificate context');
    }

    final sessionNonceStr = payload['sessionNonce'] as String?;
    final bindingType = payload['bindingType'] as String?;

    final validatedBinding = await _validateBindingType(peerDeviceId, bindingType);
    if (validatedBinding == null) return;

    if (sessionNonceStr == null) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'Missing sessionNonce');
      return;
    }
    late final Uint8List peerNonce;
    try {
      peerNonce = base64.decode(sessionNonceStr);
    } on FormatException {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Invalid base64 in sessionNonce');
      return;
    }
    if (peerNonce.length != 32) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'sessionNonce must be exactly 32 bytes');
      return;
    }
    final localCertDer = _identityManager.tlsCertificateDer;
    final cbInput = Uint8List(peerNonce.length + msg.peerCertDer!.length + localCertDer.length);
    cbInput.setRange(0, peerNonce.length, peerNonce);
    cbInput.setRange(peerNonce.length, peerNonce.length + msg.peerCertDer!.length, msg.peerCertDer!);
    cbInput.setRange(peerNonce.length + msg.peerCertDer!.length, cbInput.length, localCertDer);
    final channelBinding = Uint8List.fromList(sha256.convert(cbInput).bytes);

    final isValidPoP = await PoPManager.verifyIdentityProof(
      identityProofHex,
      channelBinding,
      msg.peerEd25519Key!,
      msg.peerCertDer!,
    );

    if (!isValidPoP) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Identity Misbinding / Invalid PoP Signature');
      throw SessionException('SecurityError: Identity Misbinding / Invalid PoP Signature');
    }

    ctx.handshakeState = HandshakeState.established;
    _transport.setPeerAuthenticated(peerDeviceId);
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    await _sendSessionAccept(ctx);
    await _startCapabilityNegotiation(ctx);
  }

  Future<void> _sendSessionAccept(SessionContext ctx) async {
    final localCertDer = _identityManager.tlsCertificateDer;
    final peerCertDer = _transport.getPeerCert(ctx.peerDeviceId);
    if (peerCertDer == null) throw SessionException('Cannot compute channel binding: peer cert not available');
    final sessionNonce = _generateSessionNonce();
    final channelBinding = _computeChannelBinding(sessionNonce, peerCertDer);
    final proofHex = await _identityManager.generateIdentityProof(channelBinding, localCertDer);

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
      }
    };

    await _transport.sendMessage(ctx.peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))));
  }

  Future<void> _handleSessionAccept(TransportMessage msg, Map<String, dynamic> jsonMap) async {
    final peerDeviceId = msg.peerDeviceId;
    final ctx = _sessions[peerDeviceId];

    if (ctx == null || ctx.handshakeState != HandshakeState.handshaking) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'Unexpected session.accept');
      return;
    }

    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Missing payload');
      return;
    }

    final identityVerified = payload['identityVerified'];
    if (identityVerified is! bool || !identityVerified) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'Missing or invalid identityVerified');
      return;
    }

    final bindingType = payload['bindingType'] as String?;
    final validatedBinding = await _validateBindingType(peerDeviceId, bindingType);
    if (validatedBinding == null) return;

    final identityProofHex = payload['identityProof'] as String?;
    if (identityProofHex == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing identityProof');
      return;
    }

    if (msg.peerEd25519Key == null || msg.peerCertDer == null) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Missing peer certificate context');
      throw SessionException('IdentityError: Missing peer certificate context');
    }

    final sessionNonceStr = payload['sessionNonce'] as String?;
    if (sessionNonceStr == null) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'Missing sessionNonce');
      return;
    }
    late final Uint8List peerNonce;
    try {
      peerNonce = base64.decode(sessionNonceStr);
    } on FormatException {
      await _rejectSession(peerDeviceId, 'MalformedMessage', 'Invalid base64 in sessionNonce');
      return;
    }
    if (peerNonce.length != 32) {
      await _rejectSession(peerDeviceId, 'ProtocolError', 'sessionNonce must be exactly 32 bytes');
      return;
    }
    final localCertDer = _identityManager.tlsCertificateDer;
    final cbInput = Uint8List(peerNonce.length + msg.peerCertDer!.length + localCertDer.length);
    cbInput.setRange(0, peerNonce.length, peerNonce);
    cbInput.setRange(peerNonce.length, peerNonce.length + msg.peerCertDer!.length, msg.peerCertDer!);
    cbInput.setRange(peerNonce.length + msg.peerCertDer!.length, cbInput.length, localCertDer);
    final channelBinding = Uint8List.fromList(sha256.convert(cbInput).bytes);

    final isValidPoP = await PoPManager.verifyIdentityProof(
      identityProofHex,
      channelBinding,
      msg.peerEd25519Key!,
      msg.peerCertDer!,
    );

    if (!isValidPoP) {
      await _rejectSession(peerDeviceId, 'AuthenticationFailed', 'Identity Misbinding / Invalid PoP Signature');
      throw SessionException('SecurityError: Identity Misbinding / Invalid PoP Signature');
    }

    ctx.handshakeState = HandshakeState.established;
    _transport.setPeerAuthenticated(peerDeviceId);
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    await _startCapabilityNegotiation(ctx);
  }

  Future<void> _handleSessionReject(TransportMessage msg, Map<String, dynamic> jsonMap) async {
    final peerDeviceId = msg.peerDeviceId;
    final waiter = _establishmentWaiters.remove(peerDeviceId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    final ctx = _sessions.remove(peerDeviceId);
    ctx?.dispose();
    _transport.disconnect(peerDeviceId);
  }

  Future<void> _startCapabilityNegotiation(SessionContext ctx) async {
    ctx.localAdvertisedCapabilities = _defaultCapabilities;

    ctx.capabilityNegotiationTimer?.cancel();
    ctx.capabilityNegotiationTimer = Timer(const Duration(seconds: 5), () {
      if (ctx.negotiatedCapabilities.isEmpty) {
        _rejectSession(ctx.peerDeviceId, 'Timeout', 'Capability negotiation timed out');
      }
    });
    
    final payload = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'type': 'capability.advertise',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': ctx.peerDeviceId,
      'payload': {
        'capabilities': ctx.localAdvertisedCapabilities.map((c) => c.toJson()).toList(),
      }
    };
    unawaited(
      _transport
          .sendMessage(ctx.peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(payload))))
          .catchError((_) {
        _transport.disconnect(ctx.peerDeviceId);
      }),
    );
  }

  Future<void> _handleCapabilityAdvertise(SessionContext ctx, TransportMessage msg, Map<String, dynamic> jsonMap) async {
    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Missing payload in capability.advertise');
      return;
    }

    List<Capability> peerCaps;
    try {
      final peerCapabilitiesList = payload['capabilities'] as List<dynamic>? ?? [];
      if (peerCapabilitiesList.length > 64) {
        await _rejectSession(ctx.peerDeviceId, 'ProtocolError', 'Too many capabilities');
        return;
      }
      peerCaps = peerCapabilitiesList.map((e) => Capability.fromJson(e as Map<String, dynamic>)).toList();
    } on FormatException {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Invalid capability.advertise payload');
      return;
    } on TypeError {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Invalid capability.advertise payload');
      return;
    } on ArgumentError {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Invalid capability.advertise payload');
      return;
    }

    ctx.peerAdvertisedCapabilities = peerCaps;
    for (final c in ctx.peerAdvertisedCapabilities) {
       if (c.name.length > 128 || c.policyFlags.length > 16 || c.policyFlags.any((f) => f.length > 128)) {
         await _rejectSession(ctx.peerDeviceId, 'ProtocolError', 'Capability constraint violation');
         return;
       }
    }

    if (ctx.isInitiator) {
      final selectedCaps = <Capability>[];
      for (final localCap in ctx.localAdvertisedCapabilities) {
        final peerCap = ctx.peerAdvertisedCapabilities.where((c) => c.name == localCap.name).firstOrNull;
        if (peerCap != null) {
          final selectedVersion = localCap.version < peerCap.version ? localCap.version : peerCap.version;
          if (selectedVersion >= 1) {
             selectedCaps.add(Capability(name: localCap.name, version: selectedVersion));
          }
        }
      }

      ctx.negotiatedCapabilities = selectedCaps;
      ctx.capabilityNegotiationTimer?.cancel();

      final reply = {
        'rift': '0.1-draft',
        'id': const Uuid().v4(),
        'type': 'capability.selected',
        'sourceDeviceId': _identityManager.deviceId,
        'destinationDeviceId': ctx.peerDeviceId,
        'payload': {
          'selectedCapabilities': selectedCaps.map((c) => c.toJson()).toList(),
        }
      };
      await _transport.sendMessage(ctx.peerDeviceId, Uint8List.fromList(utf8.encode(json.encode(reply))));
      
      _startHeartbeatIfTrusted(ctx);
    }
  }

  Future<void> _handleCapabilitySelected(SessionContext ctx, TransportMessage msg, Map<String, dynamic> jsonMap) async {
    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Missing payload in capability.selected');
      return;
    }

    List<Capability> selectedCaps;
    try {
      final selectedCapsList = payload['selectedCapabilities'] as List<dynamic>? ?? [];
      selectedCaps = selectedCapsList.map((e) => Capability.fromJson(e as Map<String, dynamic>)).toList();
    } on FormatException {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Invalid capability.selected payload');
      return;
    } on TypeError {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Invalid capability.selected payload');
      return;
    } on ArgumentError {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Invalid capability.selected payload');
      return;
    }

    for (final cap in selectedCaps) {
      final localCap = ctx.localAdvertisedCapabilities.where((c) => c.name == cap.name).firstOrNull;
      if (localCap == null || localCap.version < cap.version) {
        await _rejectSession(ctx.peerDeviceId, 'ProtocolError', 'Invalid capability selection: not advertised or version exceeds local');
        return;
      }
      final peerCap = ctx.peerAdvertisedCapabilities.where((c) => c.name == cap.name).firstOrNull;
      if (peerCap == null || peerCap.version < cap.version) {
        await _rejectSession(ctx.peerDeviceId, 'ProtocolError', 'Invalid capability selection: not advertised by peer');
        return;
      }
    }

    ctx.negotiatedCapabilities = selectedCaps;
    ctx.capabilityNegotiationTimer?.cancel();
    _startHeartbeatIfTrusted(ctx);
  }

  void _startHeartbeatIfTrusted(SessionContext ctx) {
    final hasAllRequiredCaps = _requiredCapabilityNames.every(ctx.hasCapability);
    if (ctx.trustState == TrustState.trusted && hasAllRequiredCaps) {
      ctx.currentPresenceStatus = 'online';
      ctx.lastHeartbeatReceived = DateTime.now();
      _presenceUpdateController.add(ctx);

      ctx.heartbeatTimer?.cancel();
      ctx.heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(
          _sendHeartbeat(ctx).catchError((Object error, StackTrace stackTrace) {
            _transport.disconnect(ctx.peerDeviceId);
          }),
        );
      });

      _resetOfflineTimeout(ctx);
      unawaited(
        _sendHeartbeat(ctx).catchError((Object error, StackTrace stackTrace) {
          _transport.disconnect(ctx.peerDeviceId);
        }),
      );
    }
  }

  void _resetOfflineTimeout(SessionContext ctx) {
    ctx.offlineTimeoutTimer?.cancel();
    ctx.offlineTimeoutTimer = Timer(const Duration(seconds: 90), () {
      ctx.currentPresenceStatus = 'offline';
      _presenceUpdateController.add(ctx);
    });
  }

  Future<void> _sendHeartbeat(SessionContext ctx) async {
    final payload = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'type': 'presence.update',
      'sourceDeviceId': _identityManager.deviceId,
      'destinationDeviceId': ctx.peerDeviceId,
      'payload': {
        'status': 'online',
        'capabilities': ctx.negotiatedCapabilities.map((c) => c.name).toList(),
      }
    };
    await _transport.sendMessage(
      ctx.peerDeviceId,
      Uint8List.fromList(utf8.encode(json.encode(payload))),
    );
  }

  Future<void> _handlePresenceUpdate(SessionContext ctx, TransportMessage msg, Map<String, dynamic> jsonMap) async {
    requireCapability(ctx.peerDeviceId, 'presence.basic');
    
    final payload = jsonMap['payload'] as Map<String, dynamic>?;
    if (payload == null) return;
    
    final status = payload['status'] as String?;
    if (status != 'online' && status != 'offline' && status != 'away') {
      await _rejectSession(ctx.peerDeviceId, 'ProtocolError', 'Invalid presence status');
      return;
    }

    List<String> reportedCaps;
    try {
      final caps = payload['capabilities'] as List<dynamic>? ?? [];
      reportedCaps = caps.cast<String>();
    } catch (e) {
      await _rejectSession(ctx.peerDeviceId, 'MalformedMessage', 'Invalid presence.update capabilities format');
      return;
    }

    for (final cap in reportedCaps) {
      if (!ctx.hasCapability(cap)) {
        await _rejectSession(ctx.peerDeviceId, 'ProtocolError', 'Unnegotiated capability in presence update');
        return;
      }
    }
    
    ctx.currentPresenceStatus = status!;
    ctx.lastHeartbeatReceived = DateTime.now();
    await _trustStore.updateLastSeen(ctx.peerDeviceId, ctx.lastHeartbeatReceived!);
    _resetOfflineTimeout(ctx);
    
    _presenceUpdateController.add(ctx);
  }

  Future<bool> _isPeerAllowedForSession(String peerDeviceId) async {
    final resolver = peerAllowanceResolver;
    if (resolver == null) return true;
    return await resolver(peerDeviceId);
  }
}
