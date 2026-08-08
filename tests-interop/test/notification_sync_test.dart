import 'dart:convert';

import 'package:daemon_dart/src/daemon.dart';
import 'package:test/test.dart';

const _iconA = <String, dynamic>{
  'mediaType': 'image/png',
  'dataBase64': 'AQID',
  'byteSize': 3,
  'sha256': '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
};

const _iconB = <String, dynamic>{
  'mediaType': 'image/png',
  'dataBase64': 'BAUG',
  'byteSize': 3,
  'sha256': '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
};

void main() {
  test(
    'Android-to-desktop notification wire shape preserves icon metadata',
    () {
      final androidRecord = <String, dynamic>{
        'notificationId': 'android:org.example.chat:1',
        'sourceDeviceId': 'rift-android',
        'sourcePlatform': 'android',
        'packageName': 'org.example.chat',
        'appName': 'Example Chat',
        'postedAt': '2026-08-08T00:00:00Z',
        'isDismissible': true,
        'isOpenable': false,
        'icon': _iconA,
      };

      final wireRecord = jsonDecode(jsonEncode(androidRecord));
      final normalized = normalizeNotificationIcon(
        (wireRecord as Map<String, dynamic>)['icon'],
      );

      expect(normalized, _iconA);
    },
  );

  test(
    'updated notification replaces icon metadata without changing identity',
    () {
      final posted = <String, dynamic>{
        'notificationId': 'notification-1',
        'sourceDeviceId': 'rift-peer',
        'icon': _iconA,
      };
      final updated = <String, dynamic>{...posted, 'icon': _iconB};

      final records = <String, Map<String, dynamic>>{
        '${posted['sourceDeviceId']}:${posted['notificationId']}': posted,
      };
      records['${updated['sourceDeviceId']}:${updated['notificationId']}'] =
          updated;

      expect(records, hasLength(1));
      expect(records.values.single['notificationId'], 'notification-1');
      expect(normalizeNotificationIcon(records.values.single['icon']), _iconB);
    },
  );
}
