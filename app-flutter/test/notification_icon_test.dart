import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/notification_icon.dart';

Map<String, dynamic> buildIcon(List<int> values) {
  final bytes = Uint8List.fromList(values);
  return {
    'mediaType': 'image/png',
    'dataBase64': base64Encode(bytes),
    'byteSize': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
    'unknown': 'ignored',
  };
}

void main() {
  test('parses a canonical icon and ignores unknown fields', () {
    final icon = parseNotificationIcon(buildIcon([1, 2, 3]));

    expect(icon, isNotNull);
    expect(icon!.mediaType, 'image/png');
    expect(icon.bytes, [1, 2, 3]);
    expect(icon.sha256, sha256.convert([1, 2, 3]).toString());
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
    final wrongSize = buildIcon([1, 2])..['byteSize'] = 1;
    final wrongHash = buildIcon([1, 2])..['sha256'] = '0' * 64;

    expect(parseNotificationIcon(wrongSize), isNull);
    expect(parseNotificationIcon(wrongHash), isNull);
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

  testWidgets('uses the fallback when PNG decoding fails', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationAppIcon(metadata: buildIcon([1, 2, 3])),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
  });
}
