import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';

/// StreamJsonRpc (C# StreamJsonRpc) uses a header-delimited framing by default:
///
///   Content-Length: `<N>`\r\n
///   \r\n
///   `<N bytes of UTF-8 JSON>`
///
/// This provides a Dart-side framer that converts a byte stream into discrete
/// JSON message strings and wraps outgoing JSON strings with Content-Length.
StreamChannel<String> streamJsonRpcFramer(
  Stream<List<int>> byteStream,
  StreamSink<List<int>> byteSink,
) {
  final incomingController = StreamController<String>();
  final outgoingController = StreamController<String>();

  // Outgoing: JSON string -> header-delimited bytes.
  outgoingController.stream.listen((json) {
    final body = utf8.encode(json);
    final header = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
    byteSink.add(header);
    byteSink.add(body);
  }, onDone: () {
    byteSink.close();
  }, onError: (e, st) {
    byteSink.addError(e, st);
  });

  // Incoming: bytes -> JSON string events.
  final buffer = <int>[];
  int? contentLength;

  void tryParse() {
    while (true) {
      if (contentLength == null) {
        final headerEnd = _indexOfDoubleCrlf(buffer);
        if (headerEnd == -1) return;

        final headerBytes = buffer.sublist(0, headerEnd);
        final headerText = ascii.decode(headerBytes);
        final len = _parseContentLength(headerText);
        if (len == null) {
          incomingController.addError(
            FormatException('Missing/invalid Content-Length header: "$headerText"'),
          );
          buffer.clear();
          return;
        }

        // Consume header + \r\n\r\n
        buffer.removeRange(0, headerEnd + 4);
        contentLength = len;
      }

      if (contentLength != null) {
        final len = contentLength!;
        if (buffer.length < len) return;
        final bodyBytes = buffer.sublist(0, len);
        buffer.removeRange(0, len);
        contentLength = null;

        incomingController.add(utf8.decode(bodyBytes));
        continue;
      }
    }
  }

  byteStream.listen((chunk) {
    buffer.addAll(chunk);
    tryParse();
  }, onDone: () {
    incomingController.close();
  }, onError: (e, st) {
    incomingController.addError(e, st);
  });

  return StreamChannel<String>(incomingController.stream, outgoingController.sink);
}

int _indexOfDoubleCrlf(List<int> data) {
  for (var i = 0; i + 3 < data.length; i++) {
    if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

int? _parseContentLength(String headerText) {
  // Support multiple header lines; match case-insensitive "Content-Length".
  for (final line in headerText.split('\r\n')) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final name = line.substring(0, idx).trim().toLowerCase();
    if (name != 'content-length') continue;
    final value = line.substring(idx + 1).trim();
    return int.tryParse(value);
  }
  return null;
}
