
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class FrameCodecException implements Exception {
  final String message;
  FrameCodecException(this.message);
  @override
  String toString() => 'FrameCodecException: $message';
}

/// Provides framing for Rift protocol messages:
/// 4-byte big-endian length prefix + UTF-8 JSON object.
/// Maximum frame size is 32 MiB.
class RiftFrameCodec {
  static const int maxFrameSizePreAuth = 64 * 1024; // 64 KiB
  static const int maxFrameSizePostAuth = 32 * 1024 * 1024; // 32 MiB

  /// Encodes a JSON object into a Rift protocol frame.
  static Uint8List encode(Map<String, dynamic> payload) {
    var jsonString = json.encode(payload);
    var payloadBytes = utf8.encode(jsonString);
    var length = payloadBytes.length;

    if (length == 0) {
      throw FrameCodecException('Cannot encode empty payload');
    }
    if (length > maxFrameSizePostAuth) {
      throw FrameCodecException('Payload too large: $length bytes (absolute max $maxFrameSizePostAuth)');
    }

    var frame = Uint8List(4 + length);
    var byteData = ByteData.view(frame.buffer);
    
    // Write 4-byte big-endian length
    byteData.setUint32(0, length, Endian.big);
    
    // Write payload
    frame.setRange(4, frame.length, payloadBytes);
    
    return frame;
  }

  /// Decodes a Rift protocol frame into a JSON object.
  /// Note: The input [frameBytes] must be EXACTLY the complete frame
  /// (length prefix + payload). Stream chunking must be handled at the transport layer.
  static Map<String, dynamic> decode(Uint8List frameBytes) {
    if (frameBytes.length < 4) {
      throw FrameCodecException('Frame too small to contain length prefix');
    }

    var byteData = ByteData.view(frameBytes.buffer, frameBytes.offsetInBytes, frameBytes.lengthInBytes);
    var declaredLength = byteData.getUint32(0, Endian.big);

    if (declaredLength == 0) {
      throw FrameCodecException('MalformedMessage: zero-length frame');
    }

    if (declaredLength > maxFrameSizePostAuth) {
      throw FrameCodecException('PayloadTooLarge: declared length $declaredLength exceeds absolute max $maxFrameSizePostAuth');
    }

    if (frameBytes.length - 4 != declaredLength) {
      throw FrameCodecException('Frame length mismatch: declared $declaredLength but got ${frameBytes.length - 4}');
    }

    var payloadBytes = Uint8List.view(frameBytes.buffer, frameBytes.offsetInBytes + 4, declaredLength);
    
    return _validateAndDecodeJsonObject(payloadBytes);
  }

  static Map<String, dynamic> _validateAndDecodeJsonObject(Uint8List payloadBytes) {
    final decodedPayload = () {
      try {
        return utf8.decode(payloadBytes);
      } catch (e) {
        throw FrameCodecException('MalformedMessage: invalid UTF-8 sequence');
      }
    }();

    try {
      final parsed = json.decode(decodedPayload);
      if (parsed is! Map<String, dynamic>) {
        throw FrameCodecException('MalformedMessage: non-object JSON value');
      }
      return parsed;
    } on FrameCodecException {
      rethrow;
    } catch (e) {
      throw FrameCodecException('MalformedMessage: invalid JSON payload');
    }
  }
}

/// A StreamTransformer that incrementally processes a byte stream into decoded Rift frames.
/// Prevents Memory Exhaustion (OOM) by enforcing the maxFrameSize directly on the stream chunks.
class RiftFrameTransformer extends StreamTransformerBase<List<int>, Map<String, dynamic>> {
  final int Function() maxFrameSizeProvider;

  RiftFrameTransformer({int Function()? maxFrameSizeProvider}) 
      : maxFrameSizeProvider = maxFrameSizeProvider ?? (() => RiftFrameCodec.maxFrameSizePreAuth);

  @override
  Stream<Map<String, dynamic>> bind(Stream<List<int>> stream) async* {
    var buffer = BytesBuilder(copy: false);
    int? expectedLength;
    int currentLimit = maxFrameSizeProvider() + 4; // Default safe limit

    try {
      await for (var chunk in stream) {
        if (buffer.length + chunk.length > currentLimit) {
          throw FrameCodecException('PayloadTooLarge: buffer accumulation exceeded safe limit');
        }
        buffer.add(chunk);

        while (true) {
          if (expectedLength == null) {
            if (buffer.length >= 4) {
              var bytes = buffer.takeBytes();
              var byteData = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
              expectedLength = byteData.getUint32(0, Endian.big);
              buffer.add(bytes.sublist(4));

              if (expectedLength == 0) {
                throw FrameCodecException('MalformedMessage: zero-length frame');
              }
              if (expectedLength > maxFrameSizeProvider()) {
                throw FrameCodecException('PayloadTooLarge: declared length $expectedLength exceeds current max ${maxFrameSizeProvider()}');
              }
              
              // Limit strictly to this frame's size + a safe margin for the incoming chunk (64 KiB)
              currentLimit = expectedLength + (64 * 1024);
            } else {
              break; // Wait for more bytes
            }
          }

          if (buffer.length >= expectedLength) {
            var bytes = buffer.takeBytes();
            var frameData = bytes.sublist(0, expectedLength);
            buffer.add(bytes.sublist(expectedLength)); // Re-add the remaining bytes

            yield RiftFrameCodec._validateAndDecodeJsonObject(
              Uint8List.fromList(frameData),
            );
            expectedLength = null; // Reset for the next frame
            currentLimit = maxFrameSizeProvider() + 4;
          } else {
            break; // Wait for more bytes to complete the current frame
          }
        }
      }

      if (expectedLength != null || buffer.length > 0) {
        throw FrameCodecException('Unexpected end of stream with incomplete frame');
      }
    } finally {
      buffer.clear();
    }
  }
}
