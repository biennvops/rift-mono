import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:nsd/nsd.dart' as nsd;
import '../interfaces/discovery_service.dart';

class DiscoveryServiceException implements Exception {
  final String message;
  final dynamic cause;
  DiscoveryServiceException(this.message, [this.cause]);
  @override
  String toString() => 'DiscoveryServiceException: $message ${cause != null ? '(Cause: $cause)' : ''}';
}

class MdnsDiscoveryService implements DiscoveryService {
  // Constants avoid hardcoding business rules (Rule 2.3)
  static const String _serviceType = '_rift._tcp';
  
  final String _deviceName;
  final int _port;

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  
  final StreamController<nsd.Service> _deviceDiscoveredController = StreamController<nsd.Service>.broadcast();

  MdnsDiscoveryService({
    required String deviceName,
    required int port,
  })  : _deviceName = deviceName,
        _port = port;

  @override
  Stream<dynamic> get onDeviceDiscovered => _deviceDiscoveredController.stream;

  @override
  Future<void> startAdvertising() async {
    if (_registration != null) {
      developer.log('mDNS advertising is already running.', name: 'MdnsDiscoveryService');
      return;
    }

    try {
      final service = nsd.Service(
        name: _deviceName,
        type: _serviceType,
        port: _port,
        txt: {
          'minVersion': utf8.encode('0.1-draft'),
          'maxVersion': utf8.encode('0.1-draft'),
        },
      );
      
      _registration = await nsd.register(service);
      developer.log('Started mDNS advertising: $_deviceName on port $_port', name: 'MdnsDiscoveryService');
    } catch (e, stackTrace) {
      developer.log(
        'Failed to start mDNS advertising',
        name: 'MdnsDiscoveryService',
        error: e,
        stackTrace: stackTrace,
      );
      throw DiscoveryServiceException('Failed to start mDNS advertising', e);
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (_registration == null) return;
    try {
      await nsd.unregister(_registration!);
      _registration = null;
      developer.log('Stopped mDNS advertising', name: 'MdnsDiscoveryService');
    } catch (e, stackTrace) {
      developer.log(
        'Failed to stop mDNS advertising',
        name: 'MdnsDiscoveryService',
        error: e,
        stackTrace: stackTrace,
      );
      throw DiscoveryServiceException('Failed to stop mDNS advertising', e);
    }
  }

  @override
  Future<void> startDiscovery() async {
    if (_discovery != null) {
      developer.log('mDNS discovery is already running.', name: 'MdnsDiscoveryService');
      return;
    }

    try {
      _discovery = await nsd.startDiscovery(_serviceType);
      developer.log('Started mDNS discovery for $_serviceType', name: 'MdnsDiscoveryService');

      _discovery!.addListener(() {
        for (var service in _discovery!.services) {
          developer.log('Discovered device: ${service.name} at ${service.host}:${service.port}', name: 'MdnsDiscoveryService');
          _deviceDiscoveredController.add(service);
        }
      });
    } catch (e, stackTrace) {
      developer.log(
        'Failed to start mDNS discovery',
        name: 'MdnsDiscoveryService',
        error: e,
        stackTrace: stackTrace,
      );
      throw DiscoveryServiceException('Failed to start mDNS discovery', e);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    if (_discovery == null) return;
    try {
      await nsd.stopDiscovery(_discovery!);
      _discovery = null;
      developer.log('Stopped mDNS discovery', name: 'MdnsDiscoveryService');
    } catch (e, stackTrace) {
      developer.log(
        'Failed to stop mDNS discovery',
        name: 'MdnsDiscoveryService',
        error: e,
        stackTrace: stackTrace,
      );
      throw DiscoveryServiceException('Failed to stop mDNS discovery', e);
    }
  }
}
