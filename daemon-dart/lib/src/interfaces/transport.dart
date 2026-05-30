abstract class Transport {
  Future<void> startServer();
  Future<void> connectTo(String host, int port);
  Stream<dynamic> get onMessageReceived;
  Future<void> sendMessage(String deviceId, dynamic message);
}
