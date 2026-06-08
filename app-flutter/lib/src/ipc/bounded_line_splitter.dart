import 'dart:async';

/// A custom LineSplitter that throws an exception if a single line exceeds the max size.
/// This prevents OOM (Out Of Memory) attacks where a malicious or buggy daemon
/// sends a massive continuous payload without a newline character.
/// According to protocol.md, the max JSON frame size is 32 MiB.
class BoundedLineSplitter extends StreamTransformerBase<String, String> {
  final int maxLength;

  const BoundedLineSplitter({this.maxLength = 32 * 1024 * 1024}); // 32 MiB

  @override
  Stream<String> bind(Stream<String> stream) async* {
    final buffer = StringBuffer();

    await for (final chunk in stream) {
      var i = 0;
      while (i < chunk.length) {
        final index = chunk.indexOf('\n', i);
        if (index != -1) {
          buffer.write(chunk.substring(i, index));
          _checkLength(buffer);
          
          var line = buffer.toString();
          if (line.endsWith('\r')) {
            line = line.substring(0, line.length - 1);
          }
          yield line;
          buffer.clear();
          i = index + 1;
        } else {
          buffer.write(chunk.substring(i));
          _checkLength(buffer);
          break;
        }
      }
    }

    if (buffer.isNotEmpty) {
      var line = buffer.toString();
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      yield line;
      buffer.clear();
    }
  }

  void _checkLength(StringBuffer buffer) {
    if (buffer.length > maxLength) {
      throw FormatException('NDJSON line exceeded max length of $maxLength bytes.');
    }
  }
}
