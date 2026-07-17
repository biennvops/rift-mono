import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'ipc/json_rpc_client.dart';

Future<void> persistNotificationSyncPolicyPreferences({
  required bool enabled,
  required List<String> blacklistedPackages,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(AppPrefs.notificationSyncEnabled, enabled);
  await prefs.setStringList(
    AppPrefs.notificationSyncBlacklist,
    blacklistedPackages,
  );
}

Future<void> pushSavedNotificationSyncPolicy(
  JsonRpcRiftClient client,
) async {
  if (!client.isConnected) {
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final enabled = prefs.getBool(AppPrefs.notificationSyncEnabled) ?? true;
  final blacklist =
      prefs.getStringList(AppPrefs.notificationSyncBlacklist) ??
          const <String>[];

  await client.updateNotificationSyncPolicy(
    enabled: enabled,
    blacklistedPackages: blacklist,
  );
}
