import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/media_playback/artwork_palette.dart';

Future<Uint8List> imageBytes(void Function(Canvas canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Map<String, Object?> artworkPayload(Uint8List bytes) => {
      'mediaType': 'image/png',
      'dataBase64': base64Encode(bytes),
      'byteSize': bytes.length,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('extracts normalized accents from deterministic artwork', () async {
    final redBytes = await imageBytes((canvas) {
      canvas.drawColor(const Color(0xFFD62828), BlendMode.src);
    });
    final blueBytes = await imageBytes((canvas) {
      canvas.drawColor(const Color(0xFF2457D6), BlendMode.src);
    });

    final red = await extractArtworkAccent(redBytes);
    final blue = await extractArtworkAccent(blueBytes);

    expect(red, isNotNull);
    expect(blue, isNotNull);
    expect(HSLColor.fromColor(red!).hue, anyOf(lessThan(20), greaterThan(340)));
    expect(HSLColor.fromColor(blue!).hue, inInclusiveRange(200, 250));
    expect(HSLColor.fromColor(red).lightness, inInclusiveRange(0.38, 0.62));
  });

  test('ignores transparent and black-white pixels', () async {
    final transparent = await imageBytes((canvas) {
      canvas.drawColor(const Color(0x00000000), BlendMode.src);
    });
    final mixed = await imageBytes((canvas) {
      canvas.drawColor(Colors.white, BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 3, 8),
        Paint()..color = const Color(0xFFC92A2A),
      );
      canvas.drawRect(
        const Rect.fromLTWH(7, 0, 1, 8),
        Paint()..color = Colors.black,
      );
    });

    expect(await extractArtworkAccent(transparent), isNull);
    final accent = await extractArtworkAccent(mixed);
    expect(accent, isNotNull);
    expect(
      HSLColor.fromColor(accent!).hue,
      anyOf(lessThan(20), greaterThan(340)),
    );
  });

  test('invalid and missing artwork falls back without throwing', () async {
    expect(MediaArtwork.tryParse(null), isNull);
    expect(MediaArtwork.tryParse(const {'mediaType': 'image/png'}), isNull);
    expect(
      MediaArtwork.tryParse(const {
        'mediaType': 'image/png',
        'dataBase64': 'not base64',
      }),
      isNull,
    );
    expect(
      MediaArtwork.tryParse(const {
        'mediaType': 'image/svg+xml',
        'dataBase64': 'PHN2Zy8+',
      }),
      isNull,
    );
    expect(
      await extractArtworkAccent(Uint8List.fromList(const [1, 2, 3])),
      isNull,
    );
  });

  test('accent extraction is cached and bounded', () async {
    final redBytes = await imageBytes((canvas) {
      canvas.drawColor(const Color(0xFFD62828), BlendMode.src);
    });
    final blueBytes = await imageBytes((canvas) {
      canvas.drawColor(const Color(0xFF2457D6), BlendMode.src);
    });
    final red = MediaArtwork.tryParse(artworkPayload(redBytes))!;
    final blue = MediaArtwork.tryParse(artworkPayload(blueBytes))!;
    final cache = ArtworkAccentCache(maxEntries: 1);

    final first = await cache.resolve(red);
    final second = await cache.resolve(red);
    expect(second, first);
    expect(cache.debugExtractionCount, 1);

    await cache.resolve(blue);
    expect(cache.debugEntryCount, 1);
    expect(cache.debugExtractionCount, 2);
    await cache.resolve(red);
    expect(cache.debugExtractionCount, 3);
  });
}
