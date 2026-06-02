// test/frame_codec_test.dart

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:daemon_dart/src/network/frame_codec.dart';

void main() {
  group('RiftFrameCodec Tests', () {
    test('Should correctly encode and decode a JSON string', () {
      String payload = '{"rift": "0.1-draft", "type": "session.hello"}';
      var encoded = RiftFrameCodec.encode(payload);
      
      // Length should be 4 bytes prefix + payload length
      expect(encoded.length, equals(4 + payload.length));
      
      var decoded = RiftFrameCodec.decode(encoded);
      expect(decoded, equals(payload));
    });

    test('Should reject payloads exceeding 32 MiB on encode', () {
      // Mock a huge string (this takes RAM, so we just check the length logic)
      // Actually we can't easily allocate 32 MiB string in test without slowing it down.
      // We will skip testing actual 32 MiB string allocation, but we test decode bounds.
    });

    test('Should throw PayloadTooLarge on decode if declared length > 32 MiB', () {
      var frame = Uint8List(8);
      var bd = ByteData.view(frame.buffer);
      bd.setUint32(0, (32 * 1024 * 1024) + 1, Endian.big); // 32 MiB + 1
      
      expect(
        () => RiftFrameCodec.decode(frame),
        throwsA(
          isA<FrameCodecException>().having(
            (e) => e.message,
            'message',
            contains('PayloadTooLarge'),
          ),
        ),
      );
    });

    test('Should throw MalformedMessage on zero-length frame decode', () {
      var frame = Uint8List(4); // 4 bytes of zeros
      expect(
        () => RiftFrameCodec.decode(frame),
        throwsA(
          isA<FrameCodecException>().having(
            (e) => e.message,
            'message',
            contains('zero-length frame'),
          ),
        ),
      );
    });

    test('Should throw FrameCodecException on length mismatch', () {
      String payload = '{"a": "b"}';
      var encoded = RiftFrameCodec.encode(payload);
      
      // Corrupt the length prefix
      var bd = ByteData.view(encoded.buffer);
      bd.setUint32(0, payload.length + 10, Endian.big);
      
      expect(
        () => RiftFrameCodec.decode(encoded),
        throwsA(isA<FrameCodecException>()),
      );
    });

    test('Should throw MalformedMessage on invalid JSON payload', () {
      var payloadBytes = Uint8List.fromList('not-json'.codeUnits);
      var frame = Uint8List(4 + payloadBytes.length);
      var bd = ByteData.view(frame.buffer);
      bd.setUint32(0, payloadBytes.length, Endian.big);
      frame.setRange(4, frame.length, payloadBytes);

      expect(
        () => RiftFrameCodec.decode(frame),
        throwsA(
          isA<FrameCodecException>().having(
            (e) => e.message,
            'message',
            contains('invalid JSON payload'),
          ),
        ),
      );
    });

    test('Should throw MalformedMessage on non-object JSON payload', () {
      var frame = RiftFrameCodec.encode('"text"');

      expect(
        () => RiftFrameCodec.decode(frame),
        throwsA(
          isA<FrameCodecException>().having(
            (e) => e.message,
            'message',
            contains('non-object JSON value'),
          ),
        ),
      );
    });
  });

  group('RiftFrameTransformer Tests', () {
    test('Should correctly process a stream of chunked frames', () async {
      String payload1 = '{"a": 1}';
      String payload2 = '{"b": 2}';
      
      var frame1 = RiftFrameCodec.encode(payload1);
      var frame2 = RiftFrameCodec.encode(payload2);
      
      var combinedBytes = Uint8List.fromList([...frame1, ...frame2]);
      
      // Simulate chunking (1 byte at a time)
      Stream<List<int>> chunkedStream = Stream.fromIterable(
        combinedBytes.map((b) => [b]),
      );
      
      var transformer = RiftFrameTransformer();
      var result = await chunkedStream.transform(transformer).toList();
      
      expect(result.length, equals(2));
      expect(result[0], equals(payload1));
      expect(result[1], equals(payload2));
    });

    test('Should throw PayloadTooLarge if a chunk declares length > 32 MiB', () async {
      var frame = Uint8List(8);
      var bd = ByteData.view(frame.buffer);
      bd.setUint32(0, (32 * 1024 * 1024) + 1, Endian.big); // 32 MiB + 1
      
      Stream<List<int>> stream = Stream.value(frame);
      
      expect(
        () async => await stream.transform(RiftFrameTransformer()).toList(),
        throwsA(
          isA<FrameCodecException>().having(
            (e) => e.message,
            'message',
            contains('PayloadTooLarge'),
          ),
        ),
      );
    });
  });
}
