import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/media_playback/android_media_playback_publisher.dart';

void main() {
  test('normalizes Android artwork to the protocol mediaType field', () {
    final androidArtwork = <String, dynamic>{
      'mimeType': 'image/png',
      'dataBase64': 'AQID',
      'byteSize': 3,
      'sha256':
          '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
    };

    final normalized = normalizeAndroidMediaArtwork(androidArtwork);

    expect(normalized, {
      'mediaType': 'image/png',
      'dataBase64': 'AQID',
      'byteSize': 3,
      'sha256':
          '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
    });
    expect(androidArtwork, containsPair('mimeType', 'image/png'));
  });
}
