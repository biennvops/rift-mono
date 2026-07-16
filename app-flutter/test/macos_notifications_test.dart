import 'package:app_flutter/src/platform/macos_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('rift.permissions');
  final calls = <MethodCall>[];

  setUp(() {
    MacOSNotifications.debugIsMacOSOverride = true;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'notification.getStatus':
          return 'authorized';
        case 'notification.request':
          return true;
        case 'notification.show':
          return true;
        case 'share.consumePendingItems':
          return <String, Object?>{
            'route': 'history.send',
            'items': <Map<String, String>>[
              <String, String>{
                'localPath': '/tmp/shared.txt',
                'fileName': 'shared.txt',
                'mediaType': 'text/plain',
              },
            ],
          };
      }
      return null;
    });
  });

  tearDown(() {
    MacOSNotifications.debugIsMacOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('MacOSNotifications queries and requests native notification status', () async {
    expect(await MacOSNotifications.getStatus(), 'authorized');
    expect(await MacOSNotifications.request(), isTrue);

    expect(calls.map((call) => call.method), contains('notification.getStatus'));
    expect(calls.map((call) => call.method), contains('notification.request'));
  });

  test('MacOSNotifications forwards notification payload and pending share items', () async {
    final shown = await MacOSNotifications.show(
      title: 'Shared item',
      body: 'Queued in Rift',
      route: 'history.send',
      payload: const <String, Object?>{'source': 'share-extension'},
    );
    final pending = await MacOSNotifications.consumePendingShareItems();

    expect(shown, isTrue);
    expect(pending?['route'], 'history.send');
    expect((pending?['items'] as List).single['fileName'], 'shared.txt');

    final showCall = calls.firstWhere((call) => call.method == 'notification.show');
    expect(showCall.arguments, <String, Object?>{
      'title': 'Shared item',
      'body': 'Queued in Rift',
      'route': 'history.send',
      'payload': const <String, Object?>{'source': 'share-extension'},
    });
  });
}
