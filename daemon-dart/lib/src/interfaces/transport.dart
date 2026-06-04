import 'dart:typed_data';

class TransportMessage {
  final String peerDeviceId;
  final Uint8List payload;

  TransportMessage({required this.peerDeviceId, required this.payload});
}

abstract class Transport {
  Future<void> startServer();
  Future<void> stopServer();
  Future<void> connectTo(String host, int port);
  void disconnect(String peerDeviceId);
  Stream<TransportMessage> get onMessageReceived;
  Future<void> sendMessage(String deviceId, Uint8List message);
}
