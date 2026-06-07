
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:daemon_dart/src/network/frame_codec.dart';

void main() {
  group('RiftFrameCodec Tests', () {
    test('Should correctly encode and decode a JSON string', () {
      Map<String, dynamic> payload = {"rift": "0.1-draft", "type": "session.hello"};
      var encoded = RiftFrameCodec.encode(payload);
      var jsonString = json.encode(payload);
      
      // Length should be 4 bytes prefix + payload length
      expect(encoded.length, equals(4 + utf8.encode(jsonString).length));
      
      var decoded = RiftFrameCodec.decode(encoded);
      expect(decoded, equals(payload));
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
      Map<String, dynamic> payload = {"a": "b"};
      var encoded = RiftFrameCodec.encode(payload);
      
      // Corrupt the length prefix
      var bd = ByteData.view(encoded.buffer);
      bd.setUint32(0, utf8.encode(json.encode(payload)).length + 10, Endian.big);
      
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
      var payloadBytes = utf8.encode('"text"');
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
            contains('non-object JSON value'),
          ),
        ),
      );
    });
  });

  group('RiftFrameTransformer Tests', () {
    test('Should correctly process a stream of chunked frames', () async {
      Map<String, dynamic> payload1 = {"a": 1};
      Map<String, dynamic> payload2 = {"b": 2};
      
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

    test('Should throw FrameCodecException on incomplete stream', () async {
      Map<String, dynamic> payload = {"a": 1};
      var frame = RiftFrameCodec.encode(payload);
      
      // Cut the frame in half to simulate an abrupt stream end
      var incompleteFrame = frame.sublist(0, frame.length - 2);
      
      Stream<List<int>> stream = Stream.value(incompleteFrame);
      
      expect(
        () async => await stream.transform(RiftFrameTransformer()).toList(),
        throwsA(
          isA<FrameCodecException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of stream with incomplete frame'),
          ),
        ),
      );
    });
  });
}
