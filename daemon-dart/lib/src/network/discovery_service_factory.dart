import '../interfaces/discovery_service.dart';
import 'discovery_service_factory_stub.dart'
    if (dart.library.ui) 'discovery_service_factory_flutter.dart'
    as impl;

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
