import 'package:app_flutter/src/platform/windows_send_files.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rift/windows/send_files');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('parseCallbackArguments filters invalid native file items', () {
    final items = WindowsSendFiles.parseCallbackArguments(<Object?>[
      <String, Object?>{
        'localPath': r'C:\Users\Rift\report.pdf',
        'fileName': 'report.pdf',
      },
      <String, Object?>{'localPath': '', 'fileName': 'missing.pdf'},
      'invalid',
    ]);

    expect(items, <Map<String, String>>[
      <String, String>{
        'localPath': r'C:\Users\Rift\report.pdf',
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
          'localPath': r'C:\Users\Rift\photo.png',
          'fileName': 'photo.png',
        },
      ];
    });

    expect(await WindowsSendFiles.consumePendingItems(), <Map<String, String>>[
      <String, String>{
        'localPath': r'C:\Users\Rift\photo.png',
        'fileName': 'photo.png',
      },
    ]);
  });
}
