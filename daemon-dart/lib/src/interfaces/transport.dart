import 'dart:typed_data';

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
  Future<void> connectTo(String host, int port, {String? expectedDeviceId});
  void disconnect(String peerDeviceId);
  void setPeerAuthenticated(String peerDeviceId);
  Stream<TransportMessage> get onMessageReceived;
  /// Emits a peer's deviceId whenever that peer is disconnected.
  Stream<String> get onPeerDisconnected;
  Future<void> sendMessage(String deviceId, Uint8List message);
  Uint8List? getPeerCert(String peerDeviceId);
}
