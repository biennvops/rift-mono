import 'package:app_flutter/src/platform/windows_media_playback.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('rift/windows/media_playback');
  final nativeCalls = <MethodCall>[];

  setUp(() {
    WindowsMediaPlayback.debugIsWindowsOverride = true;
    nativeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    WindowsMediaPlayback.debugIsWindowsOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('WindowsMediaPlayback forwards mirrored playback payload unchanged',
      () async {
    final shown = await WindowsMediaPlayback.show(playback: const <String, Object?>{
      'sourceDeviceId': 'rift-peer',
      'playbackId': 'playback-1',
      'title': 'Test Song',
      'artist': 'Test Artist',
      'canPlay': true,
      'canPause': true,
      'canSkipNext': true,
      'canSkipPrevious': true,
      'canSeek': true,
    });

    expect(shown, isTrue);
    expect(nativeCalls.single.method, 'show');
    expect(nativeCalls.single.arguments, const <String, Object?>{
      'playback': <String, Object?>{
        'sourceDeviceId': 'rift-peer',
        'playbackId': 'playback-1',
        'title': 'Test Song',
        'artist': 'Test Artist',
        'canPlay': true,
        'canPause': true,
        'canSkipNext': true,
        'canSkipPrevious': true,
        'canSeek': true,
      },
    });
  });

  test('WindowsMediaPlayback clear forwards to native bridge', () async {
    final cleared = await WindowsMediaPlayback.clear();

    expect(cleared, isTrue);
    expect(nativeCalls.single.method, 'clear');
  });
}
