import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daemon_dart/src/file_transfer/file_transfer_service.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/operation/operation_manager.dart';

class FileTransferBenchmarkMeasurement {
  const FileTransferBenchmarkMeasurement({
    required this.offerElapsed,
    required this.activeElapsed,
    required this.rawFileBytes,
    required this.activeWireBytes,
    required this.activeMessages,
    required this.chunkMessages,
    required this.maxOutstandingSends,
  });

  final Duration offerElapsed;
  final Duration activeElapsed;
  final int rawFileBytes;
  final int activeWireBytes;
  final int activeMessages;
  final int chunkMessages;
  final int maxOutstandingSends;

  Duration get totalElapsed => offerElapsed + activeElapsed;
}

class FileTransferBenchmarkHarness {
  FileTransferBenchmarkHarness._({
    required this.transport,
    required this.sessionManager,
    required this.operationManager,
    required this.service,
    required this.temporaryDirectory,
  });

  static const peerDeviceId = 'rift-peer';
  static const localDeviceId = 'rift-local';

  final BenchmarkTransport transport;
  final SessionManager sessionManager;
  final OperationManager operationManager;
  final FileTransferService service;
  final Directory temporaryDirectory;

  static Future<FileTransferBenchmarkHarness> open() async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rift_benchmark_file_service_',
    );
    final transport = BenchmarkTransport();
    final trustStore = BenchmarkTrustStore();
    final sessionManager = SessionManager(
      transport,
      BenchmarkIdentityManager(),
      trustStore,
    );
    final operationManager = OperationManager();
    final service = FileTransferService(
      sessionManager: sessionManager,
      trustStore: trustStore,
      operationManager: operationManager,
      localDeviceId: localDeviceId,
      storagePath: temporaryDirectory.path,
    );
    final context =
        SessionContext(peerDeviceId: peerDeviceId, isInitiator: true)
          ..handshakeState = HandshakeState.established
          ..trustState = TrustState.trusted
          ..capabilityNegotiated = true
          ..negotiatedCapabilities = [
            Capability(
              name: FileTransferService.requiredCapability,
              version: 1,
            ),
          ];
    // The service benchmark reuses the session test seam instead of hand-rolling session behavior.
    // ignore: invalid_use_of_visible_for_testing_member
    sessionManager.injectContextForTesting(context);
    return FileTransferBenchmarkHarness._(
      transport: transport,
      sessionManager: sessionManager,
      operationManager: operationManager,
      service: service,
      temporaryDirectory: temporaryDirectory,
    );
  }

  Future<FileTransferBenchmarkMeasurement> runSenderPipeline({
    required File file,
    required int acceptedChunkSize,
  }) async {
    transport.resetMetrics();
    final offerWatch = Stopwatch()..start();
    final offer = await service.offerFile(
      targetDeviceId: peerDeviceId,
      localPath: file.path,
    );
    offerWatch.stop();

    final bytesBeforeActive = transport.wireBytes;
    final messagesBeforeActive = transport.messageCount;
    final chunksBeforeActive = transport.chunkMessageCount;
    final completed = service.onTransferCompleted.firstWhere(
      (event) => event['transferId'] == offer.transferId,
    );
    final activeWatch = Stopwatch()..start();
    transport.simulateIncomingMessage(peerDeviceId, {
      'rift': '0.1-draft',
      'messageId': '22222222-2222-4222-8222-222222222222',
      'type': 'file.accept',
      'sourceDeviceId': peerDeviceId,
      'destinationDeviceId': localDeviceId,
      'payload': {
        'transferId': offer.transferId,
        'receivingDeviceId': peerDeviceId,
        'chunkSize': acceptedChunkSize,
      },
    });
    await completed.timeout(const Duration(minutes: 5));
    activeWatch.stop();

    return FileTransferBenchmarkMeasurement(
      offerElapsed: offerWatch.elapsed,
      activeElapsed: activeWatch.elapsed,
      rawFileBytes: await file.length(),
      activeWireBytes: transport.wireBytes - bytesBeforeActive,
      activeMessages: transport.messageCount - messagesBeforeActive,
      chunkMessages: transport.chunkMessageCount - chunksBeforeActive,
      maxOutstandingSends: transport.maxOutstandingSends,
    );
  }

  Future<void> close() async {
    await service.dispose();
    operationManager.dispose();
    await sessionManager.dispose();
    await transport.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

class BenchmarkTransport implements Transport {
  final _messageController = StreamController<TransportMessage>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();

  int wireBytes = 0;
  int messageCount = 0;
  int chunkMessageCount = 0;
  int activeSends = 0;
  int maxOutstandingSends = 0;
  int consumeChecksum = 0;

  @override
  Stream<TransportMessage> get onMessageReceived => _messageController.stream;

  @override
  Stream<String> get onPeerDisconnected => _disconnectController.stream;

  void resetMetrics() {
    wireBytes = 0;
    messageCount = 0;
    chunkMessageCount = 0;
    activeSends = 0;
    maxOutstandingSends = 0;
    consumeChecksum = 0;
  }

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    activeSends++;
    if (activeSends > maxOutstandingSends) {
      maxOutstandingSends = activeSends;
    }
    try {
      final decoded = json.decode(utf8.decode(message));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Outbound benchmark payload was not an object.',
        );
      }
      wireBytes += message.length + 4;
      messageCount++;
      if (decoded['type'] == 'file.chunk') chunkMessageCount++;
      consumeChecksum =
          (consumeChecksum +
              message.length +
              (decoded['type'] as String).length) &
          0x7fffffff;
    } finally {
      activeSends--;
    }
  }

  void simulateIncomingMessage(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) {
    _messageController.add(
      TransportMessage(
        peerDeviceId: peerDeviceId,
        payload: Uint8List.fromList(utf8.encode(json.encode(payload))),
        peerEd25519Key: Uint8List(32),
        peerCertDer: Uint8List(32),
      ),
    );
  }

  Future<void> close() async {
    await _messageController.close();
    await _disconnectController.close();
  }

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async => expectedDeviceId ?? FileTransferBenchmarkHarness.peerDeviceId;

  @override
  void disconnect(String peerDeviceId) {
    _disconnectController.add(peerDeviceId);
  }

  @override
  Uint8List? getPeerCert(String peerDeviceId) => Uint8List(32);

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) => null;

  @override
  void setPeerAuthenticated(String peerDeviceId) {}

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {}
}

class BenchmarkIdentityManager implements IdentityManager {
  @override
  String get deviceId => FileTransferBenchmarkHarness.localDeviceId;

  @override
  String get displayName => 'Rift benchmark';

  @override
  Uint8List get tlsCertificateDer => Uint8List(32);

  @override
  String get tlsCertificatePem => 'benchmark-certificate';

  @override
  String get tlsPrivateKeyPem => 'benchmark-key';

  @override
  Future<void> dispose() async {}

  @override
  Future<String> generateIdentityProof(
    Uint8List channelBinding,
    Uint8List localCertDer,
  ) async => 'benchmark-proof';

  @override
  Uint8List getDeviceFingerprint() => Uint8List(32);

  @override
  Uint8List getEd25519PublicKey() => Uint8List(32);

  @override
  Future<void> initialize() async {}
}

class BenchmarkTrustStore implements TrustStore {
  @override
  Future<void> appendSecurityEvent(SecurityEventRecord record) async {}

  @override
  Future<int> countSecurityEvents(SecurityEventQuery query) async => 0;

  @override
  Future<void> deletePeer(String deviceId) async {}

  @override
  Future<List<PeerRecord>> getAllPeers() async => [];

  @override
  Future<PeerRecord?> getPeer(String deviceId) async => PeerRecord(
    deviceId: deviceId,
    certDer: Uint8List(32),
    state: TrustState.trusted,
    updatedAt: DateTime.now().toUtc(),
  );

  @override
  Future<List<PeerRecord>> getPeersByState(TrustState state) async => [];

  @override
  Future<void> initialize() async {}

  @override
  Future<List<SecurityEventRecord>> querySecurityEvents(
    SecurityEventQuery query,
  ) async => [];

  @override
  Future<bool> transitionState(
    String deviceId,
    TrustState from,
    TrustState to, {
    DateTime? pairedAt,
  }) async => true;

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {}

  @override
  Future<void> upsertPeer(PeerRecord record) async {}
}
