import 'package:flutter/foundation.dart';

@immutable
class ActivityNavigationRequest {
  const ActivityNavigationRequest({
    required this.route,
    this.deviceId,
    this.displayName,
  });

  final String route;
  final String? deviceId;
  final String? displayName;
}
