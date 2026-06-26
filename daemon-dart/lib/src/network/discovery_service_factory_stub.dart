import '../interfaces/discovery_service.dart';

DiscoveryService createDiscoveryService({
  required int port,
  String minVersion = '0.1-draft',
  String maxVersion = '0.1-draft',
  String? deviceIdHint,
  String? fingerprintPrefix,
}) {
  throw UnsupportedError(
    'DiscoveryServiceImpl requires Flutter plugin bindings and is unavailable '
    'in this standalone Dart runtime.',
  );
}
