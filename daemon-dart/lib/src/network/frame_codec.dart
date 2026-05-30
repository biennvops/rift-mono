// lib/src/network/frame_codec.dart

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
  static const int maxFrameSize = 32 * 1024 * 1024; // 32 MiB

  /// Encodes a JSON string into a Rift protocol frame.
  static Uint8List encode(String jsonString) {
    var payloadBytes = utf8.encode(jsonString);
    var length = payloadBytes.length;

    if (length == 0) {
      throw FrameCodecException('Cannot encode empty payload');
    }
    if (length > maxFrameSize) {
      throw FrameCodecException('Payload too large: $length bytes (max $maxFrameSize)');
    }

    var frame = Uint8List(4 + length);
    var byteData = ByteData.view(frame.buffer);
    
    // Write 4-byte big-endian length
    byteData.setUint32(0, length, Endian.big);
    
    // Write payload
    frame.setRange(4, frame.length, payloadBytes);
    
    return frame;
  }

  /// Decodes a Rift protocol frame into a JSON string.
  /// Note: The input [frameBytes] must be EXACTLY the complete frame
  /// (length prefix + payload). Stream chunking must be handled at the transport layer.
  static String decode(Uint8List frameBytes) {
    if (frameBytes.length < 4) {
      throw FrameCodecException('Frame too small to contain length prefix');
    }

    var byteData = ByteData.view(frameBytes.buffer, frameBytes.offsetInBytes, frameBytes.lengthInBytes);
    var declaredLength = byteData.getUint32(0, Endian.big);

    if (declaredLength == 0) {
      throw FrameCodecException('MalformedMessage: zero-length frame');
    }

    if (declaredLength > maxFrameSize) {
      throw FrameCodecException('PayloadTooLarge: declared length $declaredLength exceeds max $maxFrameSize');
    }

    if (frameBytes.length - 4 != declaredLength) {
      throw FrameCodecException('Frame length mismatch: declared $declaredLength but got ${frameBytes.length - 4}');
    }

    var payloadBytes = Uint8List.view(frameBytes.buffer, frameBytes.offsetInBytes + 4, declaredLength);
    
    try {
      return utf8.decode(payloadBytes);
    } catch (e) {
      throw FrameCodecException('MalformedMessage: invalid UTF-8 sequence');
    }
  }
}
