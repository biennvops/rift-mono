import 'dart:typed_data';

abstract class Transport {
  Future<void> startServer();
  Future<void> connectTo(String host, int port);
  Stream<Uint8List> get onMessageReceived;
  Future<void> sendMessage(String deviceId, Uint8List message);
}
