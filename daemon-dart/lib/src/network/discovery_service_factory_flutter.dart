import '../interfaces/discovery_service.dart';
import 'discovery_service_impl.dart';

DiscoveryService createDiscoveryService({
  required int port,
  String minVersion = '0.1-draft',
  String maxVersion = '0.1-draft',
  String? deviceIdHint,
  String? fingerprintPrefix,
}) {
  return DiscoveryServiceImpl(
    port: port,
    minVersion: minVersion,
    maxVersion: maxVersion,
    deviceIdHint: deviceIdHint,
    fingerprintPrefix: fingerprintPrefix,
  );
}
