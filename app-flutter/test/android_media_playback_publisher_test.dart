import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/media_playback/android_media_playback_publisher.dart';

void main() {
  test('normalizes Android artwork to the protocol mediaType field', () {
    final androidArtwork = <String, dynamic>{
      'mimeType': 'image/png',
      'dataBase64': 'AQID',
    };

    final normalized = normalizeAndroidMediaArtwork(androidArtwork);

    expect(normalized, {
      'mediaType': 'image/png',
      'dataBase64': 'AQID',
    });
    expect(androidArtwork, containsPair('mimeType', 'image/png'));
  });
}
