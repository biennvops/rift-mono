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
final RegExp _mediaArtworkSha256Pattern = RegExp(r'^[0-9a-f]{64}$');

Map<String, Object>? _mediaArtworkInput(Object? value) {
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
  final input = <String, Object>{
    'mediaType': mediaType,
    'dataBase64': encoded,
  };
  final suppliedIdentity = value['sha256']?.toString().toLowerCase();
  final suppliedByteSize = value['byteSize'];
  if (suppliedIdentity != null &&
      _mediaArtworkSha256Pattern.hasMatch(suppliedIdentity) &&
      suppliedByteSize is int &&
      suppliedByteSize > 0 &&
      suppliedByteSize <= mediaArtworkMaxRawBytes) {
    input['sha256'] = suppliedIdentity;
    input['byteSize'] = suppliedByteSize;
  }
  return input;
}

Map<String, Object>? _decodeMediaArtwork(Map<String, Object> input) {
  final mediaType = input['mediaType'];
  final encoded = input['dataBase64'];
  if (mediaType is! String || encoded is! String) return null;

  Uint8List bytes;
  try {
    bytes = base64Decode(encoded);
  } catch (_) {
    return null;
  }
  if (bytes.isEmpty || bytes.length > mediaArtworkMaxRawBytes) return null;

  return {
    'mediaType': mediaType,
    'bytes': bytes,
    'identity': sha256.convert(bytes).toString(),
  };
}

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
    final input = _mediaArtworkInput(value);
    return input == null
        ? null
        : _mediaArtworkFromDecoded(_decodeMediaArtwork(input));
  }
}

MediaArtwork? _mediaArtworkFromDecoded(Map<String, Object>? decoded) {
  final mediaType = decoded?['mediaType'];
  final bytes = decoded?['bytes'];
  final identity = decoded?['identity'];
  if (mediaType is! String || bytes is! Uint8List || identity is! String) {
    return null;
  }
  return MediaArtwork(
    mediaType: mediaType,
    bytes: bytes,
    identity: identity,
  );
}

class PlaybackArtworkCache {
  final Map<String, _PlaybackArtworkCacheEntry> _entries =
      <String, _PlaybackArtworkCacheEntry>{};
  int _parseCount = 0;

  @visibleForTesting
  int get debugParseCount => _parseCount;

  @visibleForTesting
  int get debugRetainedBase64Characters => _entries.values.fold(
        0,
        (total, entry) => total + (entry.pendingEncoded?.length ?? 0),
      );

  Future<MediaArtwork?> resolve(String playbackKey, Object? value) {
    final input = _mediaArtworkInput(value);
    if (input == null) {
      _entries.remove(playbackKey);
      return Future.value(null);
    }

    final existing = _entries[playbackKey];
    final mediaType = input['mediaType']! as String;
    final encoded = input['dataBase64']! as String;
    final sourceIdentity = input['sha256'] as String?;
    final sourceByteSize = input['byteSize'] as int?;
    final existingArtwork = existing?.artwork;
    if (sourceIdentity != null &&
        sourceByteSize != null &&
        existingArtwork?.identity == sourceIdentity &&
        existingArtwork?.bytes.length == sourceByteSize &&
        existingArtwork?.mediaType == mediaType) {
      _entries[playbackKey] = _PlaybackArtworkCacheEntry(
        artwork: existingArtwork,
      );
      return Future.value(existingArtwork);
    }

    final pendingSourceMatches = sourceIdentity != null &&
        sourceByteSize != null &&
        existing?.pendingSourceIdentity == sourceIdentity &&
        existing?.pendingByteSize == sourceByteSize;
    if (existing?.pending != null &&
        existing!.pendingMediaType == mediaType &&
        (pendingSourceMatches || identical(existing.pendingEncoded, encoded))) {
      return existing.pending!;
    }

    final requestToken = Object();
    final previousArtwork = existing?.artwork;
    _parseCount++;
    Future<MediaArtwork?> decodeAndCache() async {
      Map<String, Object>? decoded;
      try {
        decoded = await compute(_decodeMediaArtwork, input);
      } catch (_) {
        final current = _entries[playbackKey];
        if (identical(current?.requestToken, requestToken)) {
          _entries[playbackKey] = _PlaybackArtworkCacheEntry(
            artwork: previousArtwork,
          );
        }
        return previousArtwork;
      }

      final parsed = _mediaArtworkFromDecoded(decoded);
      final current = _entries[playbackKey];
      if (!identical(current?.requestToken, requestToken)) return parsed;

      final artwork = parsed != null &&
              previousArtwork?.identity == parsed.identity &&
              previousArtwork?.mediaType == parsed.mediaType
          ? previousArtwork
          : parsed;
      _entries[playbackKey] = _PlaybackArtworkCacheEntry(artwork: artwork);
      return artwork;
    }

    final pending = decodeAndCache();
    _entries[playbackKey] = _PlaybackArtworkCacheEntry(
      artwork: previousArtwork,
      pendingEncoded: encoded,
      pendingMediaType: mediaType,
      pendingSourceIdentity: sourceIdentity,
      pendingByteSize: sourceByteSize,
      pending: pending,
      requestToken: requestToken,
    );
    return pending;
  }

  void remove(String playbackKey) => _entries.remove(playbackKey);

  void retainOnly(Iterable<String> playbackKeys) {
    final retained = playbackKeys.toSet();
    _entries.removeWhere((key, _) => !retained.contains(key));
  }

  void clear() => _entries.clear();
}

class _PlaybackArtworkCacheEntry {
  const _PlaybackArtworkCacheEntry({
    required this.artwork,
    this.pendingEncoded,
    this.pendingMediaType,
    this.pendingSourceIdentity,
    this.pendingByteSize,
    this.pending,
    this.requestToken,
  });

  final MediaArtwork? artwork;
  final String? pendingEncoded;
  final String? pendingMediaType;
  final String? pendingSourceIdentity;
  final int? pendingByteSize;
  final Future<MediaArtwork?>? pending;
  final Object? requestToken;
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
