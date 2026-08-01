import 'package:app_flutter/src/platform/linux_send_files.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rift/linux/send_files');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('parseCallbackArguments filters invalid native file items', () {
    final items = LinuxSendFiles.parseCallbackArguments(<Object?>[
      <String, Object?>{
        'localPath': '/tmp/report.pdf',
        'fileName': 'report.pdf',
      },
      <String, Object?>{'localPath': '', 'fileName': 'missing.pdf'},
      'invalid',
    ]);

    expect(items, <Map<String, String>>[
      <String, String>{
        'localPath': '/tmp/report.pdf',
        'fileName': 'report.pdf',
      },
    ]);
  });

  test('consumePendingItems returns native startup handoff', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'consumePendingItems');
      return <Object?>[
        <String, Object?>{
          'localPath': '/tmp/photo.png',
          'fileName': 'photo.png',
        },
      ];
    });

    expect(await LinuxSendFiles.consumePendingItems(), <Map<String, String>>[
      <String, String>{
        'localPath': '/tmp/photo.png',
        'fileName': 'photo.png',
      },
    ]);
  });
}
