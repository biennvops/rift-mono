import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rift/constants.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/notification_sync_policy.dart';

class MockJsonRpcClient extends Mock implements JsonRpcRiftClient {}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('fresh install defaults to enabled all policy', () async {
    final policy = await loadNotificationSyncPolicyPreferences();

    expect(policy.enabled, isTrue);
    expect(policy.mode, NotificationSyncPolicyMode.all);
    expect(policy.packageNames, isEmpty);
  });

  test('migrates a legacy blacklist to exclude mode', () async {
    SharedPreferences.setMockInitialValues({
      AppPrefs.notificationSyncEnabled: true,
      AppPrefs.notificationSyncBlacklist: [' com.foo ', 'com.foo'],
    });

    final policy = await loadNotificationSyncPolicyPreferences();

    expect(policy.enabled, isTrue);
    expect(policy.mode, NotificationSyncPolicyMode.exclude);
    expect(policy.packageNames, ['com.foo']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AppPrefs.notificationSyncPolicyModeV2),
      'exclude',
    );
  });

  test('migrates an empty legacy blacklist to all mode', () async {
    SharedPreferences.setMockInitialValues({
      AppPrefs.notificationSyncEnabled: true,
      AppPrefs.notificationSyncBlacklist: <String>[],
    });

    final policy = await loadNotificationSyncPolicyPreferences();

    expect(policy.mode, NotificationSyncPolicyMode.all);
    expect(policy.packageNames, isEmpty);
  });

  test('valid v2 preferences win over legacy state', () async {
    SharedPreferences.setMockInitialValues({
      AppPrefs.notificationSyncEnabled: true,
      AppPrefs.notificationSyncBlacklist: ['com.legacy'],
      AppPrefs.notificationSyncPolicyEnabledV2: true,
      AppPrefs.notificationSyncPolicyModeV2: 'include',
      AppPrefs.notificationSyncPolicyPackagesV2: ['com.current'],
    });

    final policy = await loadNotificationSyncPolicyPreferences();

    expect(policy.enabled, isTrue);
    expect(policy.mode, NotificationSyncPolicyMode.include);
    expect(policy.packageNames, ['com.current']);
  });

  test('normalizes whitespace, duplicates, and empty package names', () async {
    await persistNotificationSyncPolicyPreferences(
      enabled: true,
      mode: NotificationSyncPolicyMode.exclude,
      packageNames: [' com.foo ', 'com.bar', 'com.foo', ''],
    );

    final policy = await loadNotificationSyncPolicyPreferences();

    expect(policy.packageNames, ['com.bar', 'com.foo']);
  });

  test('projects include mode to disabled legacy preferences', () async {
    await persistNotificationSyncPolicyPreferences(
      enabled: true,
      mode: NotificationSyncPolicyMode.include,
      packageNames: ['com.foo'],
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPrefs.notificationSyncEnabled), isFalse);
    expect(prefs.getStringList(AppPrefs.notificationSyncBlacklist), isEmpty);
    expect(prefs.getString(AppPrefs.notificationSyncPolicyModeV2), 'include');
  });

  test('pushSavedNotificationSyncPolicy sends canonical fields', () async {
    await persistNotificationSyncPolicyPreferences(
      enabled: true,
      mode: NotificationSyncPolicyMode.include,
      packageNames: ['com.foo'],
    );
    final client = MockJsonRpcClient();
    when(() => client.isConnected).thenReturn(true);
    when(
      () => client.updateNotificationSyncPolicy(
        enabled: any(named: 'enabled'),
        mode: any(named: 'mode'),
        packageNames: any(named: 'packageNames'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{});

    await pushSavedNotificationSyncPolicy(client);

    verify(
      () => client.updateNotificationSyncPolicy(
        enabled: true,
        mode: 'include',
        packageNames: ['com.foo'],
      ),
    ).called(1);
  });
}
