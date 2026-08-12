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
  final StreamController<Map<String, dynamic>> actionRequests =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<bool> connectionChanges =
      StreamController<bool>.broadcast();
  final List<Map<String, dynamic>> actionReports = <Map<String, dynamic>>[];
  bool acquireActionExecutorResult = true;
  int acquireActionExecutorCount = 0;
  int releaseActionExecutorCount = 0;

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onNotificationActionRequest =>
      actionRequests.stream;

  @override
  Stream<bool> get onConnectionChanged => connectionChanges.stream;

  @override
  Future<dynamic> acquireNotificationActionExecutor() async {
    acquireActionExecutorCount++;
    return <String, dynamic>{'acquired': acquireActionExecutorResult};
  }

  @override
  Future<dynamic> releaseNotificationActionExecutor() async {
    releaseActionExecutorCount++;
    return <String, dynamic>{'released': true};
  }

  @override
  Future<dynamic> reportLocalNotificationActionHandled({
    required String requestId,
    required bool success,
    String? failureReason,
    String? message,
  }) async {
    actionReports.add(<String, dynamic>{
      'requestId': requestId,
      'success': success,
      if (failureReason != null) 'failureReason': failureReason,
      if (message != null) 'message': message,
    });
    return <String, dynamic>{};
  }

  void emitActionRequest(Map<String, dynamic> request) =>
      actionRequests.add(request);

  void emitConnectionChanged(bool connected) =>
      connectionChanges.add(connected);

  Future<void> close() async {
    await actionRequests.close();
    await connectionChanges.close();
  }

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
  final List<int> removeCalls = <int>[];
  WindowsNotificationRemovalResult removalResult =
      const WindowsNotificationRemovalResult(
    status: WindowsNotificationRemovalStatus.success,
  );
  Object? removeError;

  @override
  Future<WindowsNotificationRemovalResult> removeNotification(
    int userNotificationId,
  ) async {
    removeCalls.add(userNotificationId);
    final error = removeError;
    if (error != null) {
      throw error;
    }
    return removalResult;
  }

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
  Future<bool> start() async {
    startCount++;
    return true;
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

Map<String, dynamic> _actionRequest({
  String requestId = 'request-1',
  String notificationId = 'windows:812',
  String sourceDeviceId = 'local-device',
  String action = 'dismiss',
}) =>
    <String, dynamic>{
      'requestId': requestId,
      'operationId': 'operation-1',
      'notificationId': notificationId,
      'sourceDeviceId': sourceDeviceId,
      'requestingDeviceId': 'remote-device',
      'action': action,
    };

Future<void> _pumpAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
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

  test('does not start when another IPC client owns the action executor',
      () async {
    final listener = _FakeWindowsListener();
    final client = _FakeClient()..acquireActionExecutorResult = false;
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );

    await coordinator.start();

    expect(listener.startCount, 0);
    expect(coordinator.isRunning, isFalse);
    expect(client.acquireActionExecutorCount, 1);
    expect(client.releaseActionExecutorCount, 0);
    await coordinator.dispose();
    await listener.close();
    await client.close();
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
    expect(published.single['isDismissible'], isTrue);
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
          'notificationId': 'windows:44',
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

    listener.emit({'eventType': 'removed', 'notificationId': 'windows:43'});
    listener.emit({'eventType': 'removed', 'notificationId': 'windows:44'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(published, hasLength(1));
    expect(published.single['notificationId'], 'windows:44');

    await coordinator.dispose();
    await listener.close();
  });

  test('matching dismiss removes exact target and reports success once',
      () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();

    client.emitActionRequest(_actionRequest());
    await _pumpAsync();

    expect(listener.removeCalls, <int>[812]);
    expect(client.actionReports, hasLength(1));
    expect(client.actionReports.single, {
      'requestId': 'request-1',
      'success': true,
    });

    await coordinator.dispose();
    await listener.close();
    await client.close();
  });

  test('wrong source device and platform ID fail without native remove',
      () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();

    client.emitActionRequest(_actionRequest(
      requestId: 'wrong-source',
      sourceDeviceId: 'remote-device',
    ));
    client.emitActionRequest(_actionRequest(
      requestId: 'wrong-platform',
      notificationId: 'linux:812',
    ));
    await _pumpAsync();

    expect(listener.removeCalls, isEmpty);
    expect(client.actionReports, hasLength(2));
    expect(client.actionReports[0]['failureReason'], 'PolicyDenied');
    expect(client.actionReports[1]['failureReason'], 'CapabilityUnavailable');

    await coordinator.dispose();
    await listener.close();
    await client.close();
  });

  test('rejects malformed and overflowing Windows IDs', () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();

    final invalidIds = <String>[
      'windows:',
      'windows:-1',
      'windows:abc',
      'windows:1:2',
      'windows:01',
      'windows:4294967296',
    ];
    for (var index = 0; index < invalidIds.length; index++) {
      client.emitActionRequest(_actionRequest(
        requestId: 'invalid-$index',
        notificationId: invalidIds[index],
      ));
    }
    await _pumpAsync();

    expect(listener.removeCalls, isEmpty);
    expect(client.actionReports, hasLength(invalidIds.length));
    expect(
      client.actionReports.map((report) => report['failureReason']).toSet(),
      {'CapabilityUnavailable'},
    );

    await coordinator.dispose();
    await listener.close();
    await client.close();
  });

  test('stale target fails after exact active snapshot recheck', () async {
    final listener = _FakeWindowsListener();
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();

    client.emitActionRequest(_actionRequest());
    await _pumpAsync();

    expect(listener.removeCalls, isEmpty);
    expect(
        client.actionReports.single['failureReason'], 'CapabilityUnavailable');

    await coordinator.dispose();
    await listener.close();
    await client.close();
  });

  test('maps native not found, unavailable, error, and thrown failures',
      () async {
    for (final testCase in <({
      WindowsNotificationRemovalResult? result,
      Object? error,
      String failureReason,
    })>[
      (
        result: const WindowsNotificationRemovalResult(
          status: WindowsNotificationRemovalStatus.notFound,
        ),
        error: null,
        failureReason: 'CapabilityUnavailable',
      ),
      (
        result: const WindowsNotificationRemovalResult(
          status: WindowsNotificationRemovalStatus.unavailable,
        ),
        error: null,
        failureReason: 'CapabilityUnavailable',
      ),
      (
        result: const WindowsNotificationRemovalResult(
          status: WindowsNotificationRemovalStatus.error,
        ),
        error: null,
        failureReason: 'PeerRejected',
      ),
      (
        result: null,
        error: StateError('native failure'),
        failureReason: 'PeerRejected',
      ),
    ]) {
      final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
      if (testCase.result != null) {
        listener.removalResult = testCase.result!;
      }
      listener.removeError = testCase.error;
      final client = _FakeClient();
      final coordinator = await _createCoordinator(
        listener: listener,
        client: client,
      );
      await coordinator.start();

      client.emitActionRequest(_actionRequest());
      await _pumpAsync();

      expect(listener.removeCalls, <int>[812]);
      expect(client.actionReports.single['success'], isFalse);
      expect(
        client.actionReports.single['failureReason'],
        testCase.failureReason,
      );

      await coordinator.dispose();
      await listener.close();
      await client.close();
    }
  });

  test('stopped coordinator reports unavailable without native remove',
      () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();
    listener.accessStatus = 'denied';
    await coordinator.refresh();

    client.emitActionRequest(_actionRequest());
    await _pumpAsync();

    expect(listener.removeCalls, isEmpty);
    expect(
        client.actionReports.single['failureReason'], 'CapabilityUnavailable');

    await coordinator.dispose();
    await listener.close();
    await client.close();
  });

  test('reconnect refresh reacquires the action executor lease', () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();
    client.emitConnectionChanged(false);
    await _pumpAsync();

    await coordinator.refresh();
    await coordinator.dispose();

    expect(client.acquireActionExecutorCount, 2);
    expect(client.releaseActionExecutorCount, 1);
    await listener.close();
    await client.close();
  });

  test('refresh stops when this IPC connection loses executor ownership',
      () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();
    client.acquireActionExecutorResult = false;

    await coordinator.refresh();

    expect(coordinator.isRunning, isFalse);
    expect(listener.stopCount, 1);
    expect(client.releaseActionExecutorCount, 0);
    await coordinator.dispose();
    await listener.close();
    await client.close();
  });

  test('refresh does not duplicate action subscription', () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();
    await coordinator.refresh();
    await coordinator.refresh();

    client.emitActionRequest(_actionRequest());
    await _pumpAsync();

    expect(listener.removeCalls, <int>[812]);
    expect(client.actionReports, hasLength(1));

    await coordinator.dispose();
    await listener.close();
    await client.close();
  });

  test('dispose removes action subscription', () async {
    final listener = _FakeWindowsListener(active: [_activeNotification(812)]);
    final client = _FakeClient();
    final coordinator = await _createCoordinator(
      listener: listener,
      client: client,
    );
    await coordinator.start();
    await coordinator.dispose();
    expect(client.releaseActionExecutorCount, 1);

    client.emitActionRequest(_actionRequest());
    await _pumpAsync();

    expect(listener.removeCalls, isEmpty);
    expect(client.actionReports, isEmpty);

    await listener.close();
    await client.close();
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
