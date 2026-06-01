import 'dart:async';
import 'dart:typed_data';
import 'package:nsd/nsd.dart' as nsd_lib;
import '../interfaces/discovery_service.dart';
import '../interfaces/identity_manager.dart';

class DiscoveryServiceImpl implements DiscoveryService {
  final IdentityManager _identityManager;
  final int _port;
  final String _serviceType = '_rift._tcp';
  
  nsd_lib.Registration? _registration;
  nsd_lib.Discovery? _discovery;
  
  // Cache to prevent spamming duplicate discovery events
  final Map<String, DiscoveredPeer> _knownPeers = {};
  
  final StreamController<DiscoveredPeer> _peerController = StreamController<DiscoveredPeer>.broadcast();

  DiscoveryServiceImpl(this._identityManager, this._port);

  @override
  Stream<DiscoveredPeer> get onDeviceDiscovered => _peerController.stream;

  @override
  Future<void> startAdvertising() async {
    if (_registration != null) return;
    
    // Convert strings to Uint8List for TXT records as required by nsd package
    final txtRecord = <String, Uint8List>{
      'minV': Uint8List.fromList('0.1-draft'.codeUnits),
      'maxV': Uint8List.fromList('0.1-draft'.codeUnits),
      'did': Uint8List.fromList(_identityManager.deviceId.codeUnits),
    };

    final service = nsd_lib.Service(
      name: _identityManager.deviceId, 
      type: _serviceType,
      port: _port,
      txt: txtRecord,
    );
    
    _registration = await nsd_lib.register(service);
  }

  @override
  Future<void> stopAdvertising() async {
    if (_registration != null) {
      await nsd_lib.unregister(_registration!);
      _registration = null;
    }
  }

  @override
  Future<void> startDiscovery() async {
    if (_discovery != null) return;
    
    _discovery = await nsd_lib.startDiscovery(_serviceType, autoResolve: true);
    _discovery!.addListener(() {
      for (var service in _discovery!.services) {
        if (service.name != null && service.name != _identityManager.deviceId && service.host != null) {
          
          String getTxtStr(String key, String fallback) {
            if (service.txt != null && service.txt![key] != null) {
              return String.fromCharCodes(service.txt![key]!);
            }
            return fallback;
          }

          String getTxtStrAny(List<String> keys, String fallback) {
            if (service.txt != null) {
              for (final key in keys) {
                final txtValue = service.txt![key];
                if (txtValue != null) {
                  return String.fromCharCodes(txtValue);
                }
              }
            }
            return fallback;
          }

          final peerDeviceId = getTxtStrAny(['did', 'id'], service.name!);
          final peerMinVersion = getTxtStrAny(['minV', 'version'], 'unknown');
          final peerMaxVersion = getTxtStr('maxV', peerMinVersion);
          
          final peer = DiscoveredPeer(
            deviceId: peerDeviceId,
            address: service.host!,
            port: service.port ?? 0,
            protocolVersion: peerMaxVersion,
          );
          
          // Only broadcast if it's a new peer or its connection info has changed
          bool isNewOrUpdated = true;
          if (_knownPeers.containsKey(peerDeviceId)) {
            final existing = _knownPeers[peerDeviceId]!;
            if (existing.address == peer.address && existing.port == peer.port && existing.protocolVersion == peer.protocolVersion) {
              isNewOrUpdated = false;
            }
          }
          
          if (isNewOrUpdated) {
            _knownPeers[peerDeviceId] = peer;
            _peerController.add(peer);
          }
        }
      }
    });
  }

  @override
  Future<void> stopDiscovery() async {
    if (_discovery != null) {
      await nsd_lib.stopDiscovery(_discovery!);
      _discovery = null;
    }
  }
}
