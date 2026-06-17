import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';

class FakeTransport implements Transport {
  final _messageController = StreamController<TransportMessage>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sentMessages = [];

  @override
  Stream<TransportMessage> get onMessageReceived => _messageController.stream;

  @override
  Stream<String> get onPeerDisconnected => _disconnectController.stream;

  @override
  Future<void> connectTo(String host, int port, {String? expectedDeviceId}) async {}

  @override
  void disconnect(String peerDeviceId) {
    _disconnectController.add(peerDeviceId);
  }

  @override
  Uint8List? getPeerCert(String peerDeviceId) => Uint8List(32);

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    sentMessages.add(json.decode(utf8.decode(message)));
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {}

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {}
  
  void simulateMessage(String deviceId, String type, Map<String, dynamic> payload, {String? sourceDeviceId}) {
    final map = {
      'rift': '0.1-draft',
      'id': const Uuid().v4(),
      'type': type,
      'sourceDeviceId': sourceDeviceId ?? deviceId,
      'destinationDeviceId': 'rift-local',
      'payload': payload,
    };
    _messageController.add(TransportMessage(
      peerDeviceId: deviceId,
      payload: Uint8List.fromList(utf8.encode(json.encode(map))),
      peerEd25519Key: Uint8List(32), 
      peerCertDer: Uint8List(32), 
    ));
  }
}

class FakeIdentityManager implements IdentityManager {
  @override
  String get deviceId => 'rift-local';

  @override
  Future<String> generateIdentityProof(Uint8List channelBinding, Uint8List peerCertDer) async => 'proof';

  @override
  Uint8List getDeviceFingerprint() => Uint8List(32);

  @override
  Uint8List get tlsCertificateDer => Uint8List(32);

  @override
  String get tlsCertificatePem => 'cert';

  @override
  String get tlsPrivateKeyPem => 'key';

  @override
  Uint8List getEd25519PublicKey() => Uint8List(32);

  @override
  Future<void> initialize() async {}
  
  @override
  Future<void> dispose() async {}
}

class FakeTrustStore implements TrustStore {
  TrustState _state = TrustState.trusted;
  
  void setState(TrustState s) => _state = s;

  @override
  Future<void> blockDevice(String deviceId) async {}

  @override
  Future<TrustRecord?> getTrustRecord(String deviceId) async => null;

  @override
  Future<List<TrustRecord>> getAllTrustRecords() async => [];

  @override
  Future<TrustState> getTrustState(String deviceId) async => _state;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> revokeDevice(String deviceId, {required String reason}) async {}

  @override
  Future<void> saveTrustRecord(TrustRecord record) async {}

  @override
  Future<void> unblockDevice(String deviceId) async {}

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}
}

void main() {
  late FakeTransport transport;
  late FakeIdentityManager identityManager;
  late FakeTrustStore trustStore;
  late SessionManager sessionManager;

  setUp(() {
    transport = FakeTransport();
    identityManager = FakeIdentityManager();
    trustStore = FakeTrustStore();
    sessionManager = SessionManager(transport, identityManager, trustStore);
  });

  tearDown(() {
    sessionManager.dispose();
  });

  test('advertise hợp lệ: peer gửi advertise đúng chuẩn', () async {
    final ctx = SessionContext(peerDeviceId: 'peer1', isInitiator: true);
    ctx.handshakeState = HandshakeState.established;
    ctx.trustState = TrustState.trusted;
    ctx.localAdvertisedCapabilities = [
      Capability(name: 'clipboard.offer_fetch', version: 1),
      Capability(name: 'presence.basic', version: 1),
    ];
    sessionManager.injectContextForTesting(ctx);

    transport.simulateMessage('peer1', 'capability.advertise', {
      'capabilities': [
        {'name': 'clipboard.offer_fetch', 'version': 1},
        {'name': 'presence.basic', 'version': 1},
      ]
    });

    // We yield to allow async stream to process
    await Future.delayed(Duration.zero);

    expect(transport.sentMessages.isNotEmpty, isTrue);
    final selectedReply = transport.sentMessages.firstWhere((m) => m['type'] == 'capability.selected', orElse: () => {});
    expect(selectedReply, isNotEmpty);
    
    // presence.update is also sent immediately after capability.selected if trusted
    expect(ctx.negotiatedCapabilities.length, equals(2));
    expect(ctx.currentPresenceStatus, equals('online'));
  });

  test('malformed capability payload bị reject', () async {
    final ctx = SessionContext(peerDeviceId: 'peer1', isInitiator: true);
    ctx.handshakeState = HandshakeState.established;
    sessionManager.injectContextForTesting(ctx);

    // Provide invalid type for capabilities (e.g. integer instead of string for name)
    transport.simulateMessage('peer1', 'capability.advertise', {
      'capabilities': [
        {'name': 123, 'version': 'bad_version'}
      ]
    });

    await Future.delayed(Duration.zero);
    
    expect(transport.sentMessages.isNotEmpty, isTrue);
    final reply = transport.sentMessages.last;
    expect(reply['type'], equals('session.reject'));
    expect(reply['payload']['failureReason'], equals('MalformedMessage'));
  });

  test('selected set đúng intersection: responder reject cap chưa được advertise', () async {
    final ctx = SessionContext(peerDeviceId: 'peer1', isInitiator: false);
    ctx.handshakeState = HandshakeState.established;
    ctx.localAdvertisedCapabilities = [Capability(name: 'feature_a', version: 1)];
    ctx.peerAdvertisedCapabilities = [Capability(name: 'feature_b', version: 1)]; // peer didn't advertise A
    sessionManager.injectContextForTesting(ctx);

    // Initiator tries to select feature_a even though it only advertised feature_b
    transport.simulateMessage('peer1', 'capability.selected', {
      'selectedCapabilities': [
        {'name': 'feature_a', 'version': 1}
      ]
    });

    await Future.delayed(Duration.zero);
    
    final reply = transport.sentMessages.last;
    expect(reply['type'], equals('session.reject'));
    expect(reply['payload']['failureReason'], equals('ProtocolError'));
  });

  test('presence update accepts only valid status and negotiated capabilities', () async {
    final ctx = SessionContext(peerDeviceId: 'peer1', isInitiator: true);
    ctx.handshakeState = HandshakeState.established;
    ctx.trustState = TrustState.trusted; // Must be trusted to pass requireCapability
    ctx.negotiatedCapabilities = [Capability(name: 'presence.basic', version: 1)];
    sessionManager.injectContextForTesting(ctx);

    transport.simulateMessage('peer1', 'presence.update', {
      'status': 'invalid_status',
      'capabilities': ['presence.basic']
    });

    await Future.delayed(Duration.zero);
    
    var reply = transport.sentMessages.last;
    expect(reply['type'], equals('session.reject'));
    expect(reply['payload']['message'], contains('Invalid presence status'));

    // Re-inject because previous reject caused context to be removed
    sessionManager.injectContextForTesting(ctx);

    transport.simulateMessage('peer1', 'presence.update', {
      'status': 'online',
      'capabilities': ['clipboard.offer_fetch'] // Not negotiated
    });

    await Future.delayed(Duration.zero);
    reply = transport.sentMessages.last;
    expect(reply['type'], equals('session.reject'));
    expect(reply['payload']['message'], contains('Unnegotiated capability in presence update'));
  });

  test('thiếu presence.basic capability không start heartbeat ngay cả khi trusted', () async {
    final ctx = SessionContext(peerDeviceId: 'peer1', isInitiator: true);
    ctx.handshakeState = HandshakeState.established;
    ctx.trustState = TrustState.trusted;
    ctx.localAdvertisedCapabilities = [Capability(name: 'clipboard.offer_fetch', version: 1)];
    sessionManager.injectContextForTesting(ctx);

    transport.simulateMessage('peer1', 'capability.advertise', {
      'capabilities': [
        {'name': 'clipboard.offer_fetch', 'version': 1},
      ]
    });

    await Future.delayed(Duration.zero);
    
    // Heartbeat shouldn't be sent because presence.basic is missing
    final hasPresenceUpdate = transport.sentMessages.any((m) => m['type'] == 'presence.update');
    expect(hasPresenceUpdate, isFalse);
    expect(ctx.heartbeatTimer, isNull);
  });
}
