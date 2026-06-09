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
    int currentBytes = 0;

    await for (final chunk in stream) {
      var i = 0;
      while (i < chunk.length) {
        final index = chunk.indexOf('\n', i);
        if (index != -1) {
          final part = chunk.substring(i, index);
          final partBytes = part.runes.fold(0, (int sum, int c) {
            if (c < 0x80) return sum + 1;
            if (c < 0x800) return sum + 2;
            if (c < 0x10000) return sum + 3;
            return sum + 4;
          });
          _checkLength(currentBytes + partBytes);
          currentBytes += partBytes;
          buffer.write(part);
          
          var line = buffer.toString();
          if (line.endsWith('\r')) {
            line = line.substring(0, line.length - 1);
          }
          if (line.isNotEmpty) {
            yield line;
          }
          buffer.clear();
          currentBytes = 0;
          i = index + 1;
        } else {
          final part = chunk.substring(i);
          final partBytes = part.runes.fold(0, (int sum, int c) {
            if (c < 0x80) return sum + 1;
            if (c < 0x800) return sum + 2;
            if (c < 0x10000) return sum + 3;
            return sum + 4;
          });
          _checkLength(currentBytes + partBytes);
          currentBytes += partBytes;
          buffer.write(part);
          break;
        }
      }
    }

    if (buffer.isNotEmpty) {
      var line = buffer.toString();
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.isNotEmpty) {
        yield line;
      }
      buffer.clear();
    }
  }

  void _checkLength(int currentBytes) {
    if (currentBytes > maxLength) {
      throw FormatException('NDJSON line exceeded max length of $maxLength bytes.');
    }
  }
}
