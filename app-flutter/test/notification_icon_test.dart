import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/notification_icon.dart';

final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);
final oversizedDimensionPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAgEAAAABCAYAAABHeX1IAAAAF0lEQVR4nGNgGAWjYBSMglEwCkbBiAQACAUAAVbgEW4AAAAASUVORK5CYII=',
);

Map<String, dynamic> buildIcon(List<int> values) {
  final bytes = Uint8List.fromList(values);
  return {
    'mediaType': 'image/png',
    'dataBase64': base64Encode(bytes),
    'byteSize': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
}

void main() {
  setUp(clearNotificationIconCache);

  test('reuses validated icons when metadata is unchanged', () {
    final first = parseNotificationIcon(buildIcon(pngBytes));
    final second = parseNotificationIcon(buildIcon(pngBytes));

    expect(first, isNotNull);
    expect(second, same(first));
  });

  test('does not trust a cached hash for different metadata', () {
    final valid = buildIcon(pngBytes);
    parseNotificationIcon(valid);
    final changed = <String, dynamic>{
      ...valid,
      'dataBase64': 'AQID',
      'byteSize': 3,
    };

    expect(parseNotificationIcon(changed), isNull);
  });

  test('creates canonical payloads for normalized PNG bytes', () {
    final payload = createNotificationIconPayload(Uint8List.fromList(pngBytes));

    expect(payload, isNotNull);
    expect(payload!['mediaType'], 'image/png');
    expect(payload['byteSize'], pngBytes.length);
    expect(payload['sha256'], sha256.convert(pngBytes).toString());
    expect(
      parseNotificationIcon(payload)?.bytes,
      orderedEquals(pngBytes),
    );
  });

  test('rejects invalid bytes when creating canonical payloads', () {
    expect(createNotificationIconPayload(Uint8List.fromList(<int>[1, 2, 3])),
        isNull);
  });

  test('parses a canonical icon', () {
    final icon = parseNotificationIcon(buildIcon(pngBytes));

    expect(icon, isNotNull);
    expect(icon!.mediaType, 'image/png');
    expect(icon.bytes, pngBytes);
    expect(icon.sha256, sha256.convert(pngBytes).toString());
  });

  test('drops icons with unknown fields', () {
    final value = buildIcon(pngBytes)..['unknown'] = 'ignored';
    expect(parseNotificationIcon(value), isNull);
  });

  test('drops icons with unsupported media types', () {
    final value = buildIcon([1])..['mediaType'] = 'image/svg+xml';
    expect(parseNotificationIcon(value), isNull);
  });

  test('drops icons with invalid base64', () {
    final value = buildIcon([1])..['dataBase64'] = 'not base64';
    expect(parseNotificationIcon(value), isNull);
  });

  test('drops icons with incorrect byte size or hash', () {
    final wrongSize = buildIcon(pngBytes)..['byteSize'] = 1;
    final wrongHash = buildIcon(pngBytes)..['sha256'] = '0' * 64;

    expect(parseNotificationIcon(wrongSize), isNull);
    expect(parseNotificationIcon(wrongHash), isNull);
  });

  test('drops non-PNG bytes, invalid structure, and dimensions', () {
    final invalidStructure = Uint8List.fromList(pngBytes);
    invalidStructure[45] ^= 1;

    expect(parseNotificationIcon(buildIcon([1, 2, 3])), isNull);
    expect(parseNotificationIcon(buildIcon(invalidStructure)), isNull);
    expect(
        parseNotificationIcon(buildIcon(oversizedDimensionPngBytes)), isNull);
  });

  test('drops oversized icons before decoding', () {
    final value = <String, dynamic>{
      'mediaType': 'image/png',
      'dataBase64': 'A' * notificationIconMaxBase64Characters,
      'byteSize': notificationIconMaxRawBytes,
      'sha256': '0' * 64,
    };

    expect(parseNotificationIcon(value), isNull);
  });

  test('drops null and wrong-shaped values', () {
    expect(parseNotificationIcon(null), isNull);
    expect(parseNotificationIcon('icon'), isNull);
    expect(parseNotificationIcon(<String, dynamic>{}), isNull);
  });

  testWidgets('uses the fallback for malformed PNG metadata', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationAppIcon(metadata: buildIcon([1, 2, 3])),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
  });
}
