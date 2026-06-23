import '../interfaces/discovery_service.dart';
import 'discovery_service_factory_stub.dart'
    if (dart.library.ui) 'discovery_service_factory_flutter.dart'
    as impl;

// The standalone CLI / AOT runner must not pull the Flutter-only `nsd` plugin
// into its import graph. `dart.library.ui` is the practical gate we use here:
// it is available in Flutter runtimes, and absent in standalone Dart CLI/AOT
// builds where discovery is intentionally unavailable.
DiscoveryService createDiscoveryService({
  required int port,
  String minVersion = '0.1-draft',
  String maxVersion = '0.1-draft',
  String? deviceIdHint,
  String? fingerprintPrefix,
}) {
  return impl.createDiscoveryService(
    port: port,
    minVersion: minVersion,
    maxVersion: maxVersion,
    deviceIdHint: deviceIdHint,
    fingerprintPrefix: fingerprintPrefix,
  );
}
