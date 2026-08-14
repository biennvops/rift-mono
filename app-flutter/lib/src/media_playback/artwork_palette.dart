import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const int mediaArtworkMaxRawBytes = 20 * 1024 * 1024;
const int mediaArtworkMaxBase64Characters =
    ((mediaArtworkMaxRawBytes + 2) ~/ 3) * 4;
const Set<String> _supportedArtworkTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

@immutable
class MediaArtwork {
  const MediaArtwork({
    required this.mediaType,
    required this.bytes,
    required this.identity,
  });

  final String mediaType;
  final Uint8List bytes;
  final String identity;

  static MediaArtwork? tryParse(Object? value) {
    if (value is! Map) return null;
    final mediaType = value['mediaType']?.toString().toLowerCase();
    final encoded = value['dataBase64'];
    if (mediaType == null ||
        !_supportedArtworkTypes.contains(mediaType) ||
        encoded is! String ||
        encoded.isEmpty ||
        encoded.length > mediaArtworkMaxBase64Characters) {
      return null;
    }

    Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty || bytes.length > mediaArtworkMaxRawBytes) return null;

    final digest = sha256.convert(bytes).toString();
    final suppliedDigest = value['sha256']?.toString().toLowerCase();
    final identity = suppliedDigest != null && suppliedDigest == digest
        ? suppliedDigest
        : digest;
    return MediaArtwork(
      mediaType: mediaType,
      bytes: bytes,
      identity: identity,
    );
  }
}

class ArtworkAccentCache {
  ArtworkAccentCache({this.maxEntries = 16}) : assert(maxEntries > 0);

  final int maxEntries;
  final LinkedHashMap<String, Future<Color?>> _entries =
      LinkedHashMap<String, Future<Color?>>();
  final Map<String, Color?> _resolved = <String, Color?>{};
  int _extractionCount = 0;

  @visibleForTesting
  int get debugExtractionCount => _extractionCount;

  @visibleForTesting
  int get debugEntryCount => _entries.length;

  Color? accentFor(String artworkIdentity) => _resolved[artworkIdentity];

  Future<Color?> resolve(MediaArtwork artwork) {
    final existing = _entries.remove(artwork.identity);
    if (existing != null) {
      _entries[artwork.identity] = existing;
      return existing;
    }

    if (_entries.length >= maxEntries) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest);
      _resolved.remove(oldest);
    }

    _extractionCount++;
    final future = extractArtworkAccent(artwork.bytes).then((accent) {
      if (_entries.containsKey(artwork.identity)) {
        _resolved[artwork.identity] = accent;
      }
      return accent;
    });
    _entries[artwork.identity] = future;
    return future;
  }
}

Future<Color?> extractArtworkAccent(Uint8List bytes) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 32,
      targetHeight: 32,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final pixelData =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (pixelData == null) return null;
    return _representativeAccent(pixelData.buffer.asUint8List());
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

Color? _representativeAccent(Uint8List rgba) {
  final buckets = <int, _ColorBucket>{};
  for (var offset = 0; offset + 3 < rgba.length; offset += 4) {
    final alpha = rgba[offset + 3];
    if (alpha < 128) continue;
    final red = rgba[offset];
    final green = rgba[offset + 1];
    final blue = rgba[offset + 2];
    final color = Color.fromARGB(alpha, red, green, blue);
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness <= 0.04 ||
        hsl.lightness >= 0.96 ||
        hsl.saturation < 0.12) {
      continue;
    }

    final key = (red >> 5) << 6 | (green >> 5) << 3 | (blue >> 5);
    final bucket = buckets.putIfAbsent(key, _ColorBucket.new);
    bucket.count++;
    bucket.red += red;
    bucket.green += green;
    bucket.blue += blue;
    bucket.saturation += hsl.saturation;
    bucket.lightness += hsl.lightness;
  }
  if (buckets.isEmpty) return null;

  _ColorBucket? selected;
  var selectedScore = -1.0;
  for (final bucket in buckets.values) {
    final saturation = bucket.saturation / bucket.count;
    final lightness = bucket.lightness / bucket.count;
    final score = bucket.count *
        (0.5 + saturation * 1.5) *
        (1 - (lightness - 0.5).abs() * 0.5);
    if (score > selectedScore) {
      selected = bucket;
      selectedScore = score;
    }
  }
  if (selected == null) return null;

  final color = Color.fromARGB(
    255,
    selected.red ~/ selected.count,
    selected.green ~/ selected.count,
    selected.blue ~/ selected.count,
  );
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation(hsl.saturation.clamp(0.45, 0.82).toDouble())
      .withLightness(hsl.lightness.clamp(0.38, 0.62).toDouble())
      .toColor();
}

class _ColorBucket {
  int count = 0;
  int red = 0;
  int green = 0;
  int blue = 0;
  double saturation = 0;
  double lightness = 0;
}
