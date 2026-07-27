import 'dart:typed_data';

class PeerSocketEndpoint {
  final String address;
  final int port;
  final bool isServer;

  const PeerSocketEndpoint({
    required this.address,
    required this.port,
    this.isServer = false,
  });
}

class TransportMessage {
  final String peerDeviceId;
  final Uint8List payload;
  final Uint8List? peerEd25519Key;
  final Uint8List? peerCertDer;

  TransportMessage({
    required this.peerDeviceId,
    required this.payload,
    this.peerEd25519Key,
    this.peerCertDer,
  });
}

abstract class Transport {
  Future<void> startServer();
  Future<void> stopServer();
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  });
  void disconnect(String peerDeviceId);
  void setPeerAuthenticated(String peerDeviceId);
  Stream<TransportMessage> get onMessageReceived;

  /// Emits a peer's deviceId whenever that peer is disconnected.
  Stream<String> get onPeerDisconnected;
  Future<void> sendMessage(String deviceId, Uint8List message);
  Uint8List? getPeerCert(String peerDeviceId);
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId);
}

abstract interface class BoundTransport {
  int get boundPort;
}
