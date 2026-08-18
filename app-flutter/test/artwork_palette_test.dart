import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
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
      'sha256': sha256.convert(bytes).toString(),
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

  test('resolves an Android-origin canonical artwork payload', () async {
    final bytes = await imageBytes((canvas) {
      canvas.drawColor(const Color(0xFFD62828), BlendMode.src);
    });
    final cache = PlaybackArtworkCache();

    final artwork = await cache.resolve(
      'android-peer:android-session',
      artworkPayload(bytes),
    );

    expect(artwork, isNotNull);
    expect(artwork!.mediaType, 'image/png');
    expect(artwork.bytes, orderedEquals(bytes));
  });

  test('reuses decoded artwork without retaining its Base64 source', () async {
    final bytes = await imageBytes((canvas) {
      canvas.drawColor(const Color(0xFFD62828), BlendMode.src);
    });
    final payload = artworkPayload(bytes);
    final parsedCache = PlaybackArtworkCache();
    final accentCache = ArtworkAccentCache();

    final firstFuture = parsedCache.resolve('peer:session', payload);
    expect(
      parsedCache.debugRetainedBase64Characters,
      (payload['dataBase64'] as String).length,
    );
    final first = (await firstFuture)!;
    expect(parsedCache.debugRetainedBase64Characters, 0);
    await accentCache.resolve(first);
    final repeated = (await parsedCache.resolve(
      'peer:session',
      Map<String, Object?>.from(payload),
    ))!;
    await accentCache.resolve(repeated);

    expect(repeated, same(first));
    expect(parsedCache.debugParseCount, 1);
    expect(parsedCache.debugRetainedBase64Characters, 0);
    expect(accentCache.debugExtractionCount, 1);
  });

  test('does not reuse an unverified artwork identity', () async {
    final bytes = await imageBytes((canvas) {
      canvas.drawColor(const Color(0xFFD62828), BlendMode.src);
    });
    final payload = artworkPayload(bytes)..['sha256'] = '0' * 64;
    final cache = PlaybackArtworkCache();

    await cache.resolve('peer:session', payload);
    await cache.resolve(
      'peer:session',
      Map<String, Object?>.from(payload),
    );

    expect(cache.debugParseCount, 2);
  });

  test('does not coalesce pending artwork by unverified identity', () async {
    final firstBytes = Uint8List.fromList(const [1, 2, 3]);
    final secondBytes = Uint8List.fromList(const [4, 5, 6]);
    final firstPayload = artworkPayload(firstBytes)..['sha256'] = '0' * 64;
    final secondPayload = artworkPayload(secondBytes)..['sha256'] = '0' * 64;
    final cache = PlaybackArtworkCache();

    final firstFuture = cache.resolve('peer:session', firstPayload);
    final secondFuture = cache.resolve('peer:session', secondPayload);

    expect(cache.debugParseCount, 2);
    final results = await Future.wait([firstFuture, secondFuture]);
    expect(results[0]?.bytes, orderedEquals(firstBytes));
    expect(results[1]?.bytes, orderedEquals(secondBytes));
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
