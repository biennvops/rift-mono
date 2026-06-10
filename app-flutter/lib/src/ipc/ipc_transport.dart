import 'package:stream_channel/stream_channel.dart';

/// Base interface for IPC transport mechanisms.
abstract class IpcTransport {
  /// Connects to the underlying transport and returns a StreamChannel
  /// of raw string messages (usually JSON-RPC).
  Future<StreamChannel<String>> connect();

  /// Disconnects the transport.
  Future<void> disconnect();
}
