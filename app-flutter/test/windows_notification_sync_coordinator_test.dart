import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/notification_sync/windows_notification_sync_coordinator.dart';
import 'package:rift/src/platform/windows_notification_listener.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_utils/fake_transport.dart';

final _pngBytes = Uint8List.fromList(base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
));

class _FakeClient extends JsonRpcRiftClient {
  _FakeClient({this.notifications = const <Map<String, dynamic>>[]})
      : super(FakeTransport());

  List<Map<String, dynamic>> notifications;

  @override
  bool get isConnected => true;

  @override
  Future<dynamic> getDeviceInfo() async => {'deviceId': 'local-device'};

  @override
  Future<dynamic> listNotifications() async => {
        'notifications': notifications,
      };
}

class _FakeWindowsListener implements WindowsNotificationListenerPlatform {
  _FakeWindowsListener({
    this.runtime = const WindowsNotificationListenerRuntimeStatus(
      supported: true,
      hasPackageIdentity: true,
      appUserModelId: 'Rift.Desktop!Rift',
      packageFamilyName: 'Rift.Desktop_dev!Rift',
    ),
    List<Map<String, dynamic>>? active,
  })  : accessStatus = 'allowed',
        active = active ?? <Map<String, dynamic>>[];

  @override
  bool isSupported = true;
  WindowsNotificationListenerRuntimeStatus runtime;
  String accessStatus;
  List<Map<String, dynamic>> active;
  final StreamController<Map<String, dynamic>> controller =
      StreamController<Map<String, dynamic>>.broadcast();
  int startCount = 0;
  int stopCount = 0;

  @override
  Future<WindowsNotificationListenerRuntimeStatus> getRuntimeStatus() async =>
      runtime;

  @override
  Future<String> getAccessStatus() async => accessStatus;

  @override
  Future<String> requestAccess() async => accessStatus;

  @override
  Future<List<Map<String, dynamic>>> listActiveNotifications() async => active;

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Stream<Map<String, dynamic>> get events => controller.stream;

  void emit(Map<String, dynamic> event) => controller.add(event);

  Future<void> close() => controller.close();
}

Map<String, dynamic> _activeNotification(
  int id, {
  String packageName = 'Example.App!Main',
  String appName = 'Example',
}) {
  return {
    'eventType': 'posted',
    'userNotificationId': id,
    'notificationId': 'windows:$id',
    'packageName': packageName,
    'appName': appName,
    'title': 'Title',
    'bodyPreview': 'Body',
    'postedAt': '2026-08-09T12:00:00Z',
  };
}

Future<WindowsNotificationSyncCoordinator> _createCoordinator({
  required _FakeWindowsListener listener,
  _FakeClient? client,
  List<Map<String, dynamic>>? published,
  Future<String?> Function()? getLocalDeviceId,
  bool enabled = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'notification_sync_policy_enabled_v2': enabled,
    'notification_sync_policy_mode_v2': 'all',
    'notification_sync_policy_packages_v2': <String>[],
  });
  final events = published ?? <Map<String, dynamic>>[];
  return WindowsNotificationSyncCoordinator(
    client: client ?? _FakeClient(),
    listener: listener,
    getLocalDeviceId: getLocalDeviceId,
    publishEvent: (event) async => events.add(Map<String, dynamic>.from(event)),
  );
}

void main() {
  test('starts only for packaged, allowed, enabled Windows runtime', () async {
    final listener = _FakeWindowsListener();
    final coordinator = await _createCoordinator(listener: listener);

    await coordinator.start();

    expect(listener.startCount, 1);
    expect(coordinator.isRunning, isTrue);
    await coordinator.dispose();
    await listener.close();
  });

  test('does not start for denied, unpackaged, or disabled state', () async {
    final deniedListener = _FakeWindowsListener()..accessStatus = 'denied';
    final deniedCoordinator =
        await _createCoordinator(listener: deniedListener);
    await deniedCoordinator.start();
    expect(deniedListener.startCount, 0);
    await deniedCoordinator.dispose();
    await deniedListener.close();

    final unpackagedListener = _FakeWindowsListener(
      runtime: const WindowsNotificationListenerRuntimeStatus(
        supported: true,
        hasPackageIdentity: false,
      ),
    );
    final unpackagedCoordinator =
        await _createCoordinator(listener: unpackagedListener);
    await unpackagedCoordinator.start();
    expect(unpackagedListener.startCount, 0);
    await unpackagedCoordinator.dispose();
    await unpackagedListener.close();

    final disabledListener = _FakeWindowsListener();
    final disabledCoordinator = await _createCoordinator(
      listener: disabledListener,
      enabled: false,
    );
    await disabledCoordinator.start();
    expect(disabledListener.startCount, 0);
    await disabledCoordinator.dispose();
    await disabledListener.close();
  });

  test('active snapshot posts new records and converts bounded icon metadata',
      () async {
    final listener = _FakeWindowsListener(
      active: [
        {
          ..._activeNotification(812),
          'title': 'x' * 300,
          'bodyPreview': 'y' * 1100,
          'iconBytes': _pngBytes,
        },
      ],
    );
    final published = <Map<String, dynamic>>[];
    final coordinator = await _createCoordinator(
      listener: listener,
      published: published,
    );

    await coordinator.start();

    expect(published, hasLength(1));
    expect(published.single['eventType'], 'posted');
    expect(published.single['notificationId'], 'windows:812');
    expect(published.single['sourcePlatform'], 'windows');
    expect(published.single['isDismissible'], isFalse);
    expect(published.single['isOpenable'], isFalse);
    expect((published.single['title'] as String).length, 256);
    expect((published.single['bodyPreview'] as String).length, 1024);
    expect(published.single['icon'], isNotNull);

    await coordinator.dispose();
    await listener.close();
  });

  test('active record reconciliation uses updated and removes stale local only',
      () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(2)]);
    final client = _FakeClient(
      notifications: [
        {
          'notificationId': 'windows:2',
          'sourceDeviceId': 'local-device',
          'sourcePlatform': 'windows',
        },
        {
          'notificationId': 'windows:1',
          'sourceDeviceId': 'local-device',
          'sourcePlatform': 'windows',
        },
        {
          'notificationId': 'windows:remote',
          'sourceDeviceId': 'remote-device',
          'sourcePlatform': 'windows',
        },
      ],
    );
    final published = <Map<String, dynamic>>[];
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
      published: published,
    );

    await coordinator.start();

    expect(
      published.map((event) => event['eventType']),
      containsAllInOrder(<String>['updated', 'removed']),
    );
    expect(published.last['notificationId'], 'windows:1');
    expect(
      published.where((event) => event['notificationId'] == 'windows:remote'),
      isEmpty,
    );

    await coordinator.dispose();
    await listener.close();
  });

  test('Added is posted then updated, and FIFO is preserved through removal',
      () async {
    final listener = _FakeWindowsListener();
    final published = <Map<String, dynamic>>[];
    final coordinator = await _createCoordinator(
      listener: listener,
      published: published,
    );
    await coordinator.start();

    listener.emit(_activeNotification(7));
    listener.emit({
      'eventType': 'removed',
      'notificationId': 'windows:7',
      'removedAt': '2026-08-09T12:01:00Z',
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      published.map((event) => event['eventType']),
      <String>['posted', 'removed'],
    );

    listener.emit(_activeNotification(7));
    await Future<void>.delayed(Duration.zero);
    expect(published.last['eventType'], 'posted');

    listener.emit(_activeNotification(7));
    await Future<void>.delayed(Duration.zero);
    expect(published.last['eventType'], 'updated');

    await coordinator.dispose();
    await listener.close();
  });

  test('unknown Removed is forwarded only when daemon knows local record',
      () async {
    final listener = _FakeWindowsListener();
    final client = _FakeClient(
      notifications: [
        {
          'notificationId': 'windows:known',
          'sourceDeviceId': 'local-device',
          'sourcePlatform': 'windows',
        },
      ],
    );
    final published = <Map<String, dynamic>>[];
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
      published: published,
    );
    await coordinator.start();
    published.clear();

    listener
        .emit({'eventType': 'removed', 'notificationId': 'windows:unknown'});
    listener.emit({'eventType': 'removed', 'notificationId': 'windows:known'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(published, hasLength(1));
    expect(published.single['notificationId'], 'windows:known');

    await coordinator.dispose();
    await listener.close();
  });

  test('Rift-owned notifications are ignored before normalization', () async {
    final listener = _FakeWindowsListener();
    final published = <Map<String, dynamic>>[];
    final coordinator = await _createCoordinator(
      listener: listener,
      published: published,
    );
    await coordinator.start();

    listener.emit({
      ..._activeNotification(99, packageName: 'Rift.Desktop!Rift'),
      'isRiftNotification': true,
    });
    await Future<void>.delayed(Duration.zero);

    expect(published, isEmpty);
    await coordinator.dispose();
    await listener.close();
  });
}
