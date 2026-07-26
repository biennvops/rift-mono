import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:daemon_dart/daemon_dart.dart';

import '../platform/android_native_tls.dart';

class AndroidNativePeerTransport implements Transport, BoundTransport {
  AndroidNativePeerTransport(this._identityManager, {required int port})
      : _requestedPort = port;

  final IdentityManager _identityManager;
  final int _requestedPort;
  final Map<String, _NativePeerConnection> _peers = {};
  final Set<String> _authenticatedPeers = {};
  final StreamController<TransportMessage> _messages =
      StreamController<TransportMessage>.broadcast();
  final StreamController<String> _disconnects =
      StreamController<String>.broadcast();
  bool _stopping = false;
  int _boundPort = 0;

  @override
  int get boundPort => _boundPort;

  @override
  Stream<TransportMessage> get onMessageReceived => _messages.stream;

  @override
  Stream<String> get onPeerDisconnected => _disconnects.stream;

  @override
  Future<void> startServer() async {
    _stopping = false;
    _boundPort = await AndroidNativeTls.startServer(
      certificatePem: _identityManager.tlsCertificatePem,
      privateKeyPem: _identityManager.tlsPrivateKeyPem,
      port: _requestedPort,
    );
    unawaited(_acceptLoop());
  }

  Future<void> _acceptLoop() async {
    while (!_stopping) {
      try {
        final connection = await AndroidNativeTls.accept();
        await _registerConnection(connection, isServer: true);
      } catch (_) {
        if (!_stopping) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async {
    if (forceFreshSession && expectedDeviceId != null) {
      disconnect(expectedDeviceId);
    }

    final connection = await AndroidNativeTls.connect(
      host: host,
      port: port,
      certificatePem: _identityManager.tlsCertificatePem,
      privateKeyPem: _identityManager.tlsPrivateKeyPem,
    );
    final peerDeviceId = _derivePeerDeviceId(connection.peerCertificateBase64);
    if (expectedDeviceId != null &&
        RegExp(r'^rift-[a-z2-7]{32}$').hasMatch(expectedDeviceId) &&
        expectedDeviceId != peerDeviceId) {
      await AndroidNativeTls.close(connection.connectionId);
      throw const RiftAuthenticationFailedException(
        'Peer certificate device ID does not match the expected identity',
      );
    }
    return _registerConnection(connection, isServer: false);
  }

  Future<String> _registerConnection(
    AndroidTlsConnection connection, {
    required bool isServer,
  }) async {
    final certDer = Uint8List.fromList(
      base64.decode(connection.peerCertificateBase64),
    );
    final peerEd25519Key = RiftCertDecoder.extractEd25519PublicKeyFromDer(
      certDer,
    );
    final peerDeviceId = _deviceIdForKey(peerEd25519Key);
    final existing = _peers[peerDeviceId];

    if (existing != null) {
      final retainExisting = _authenticatedPeers.contains(peerDeviceId) ||
          existing.isServer == _preferIncoming(peerDeviceId);
      if (retainExisting) {
        await AndroidNativeTls.close(connection.connectionId);
        return peerDeviceId;
      }
      await _closeConnection(existing, notify: false);
    }

    final peer = _NativePeerConnection(
      connectionId: connection.connectionId,
      peerDeviceId: peerDeviceId,
      peerCertificateDer: certDer,
      peerEd25519Key: peerEd25519Key,
      remoteAddress: connection.remoteAddress,
      remotePort: connection.remotePort,
      isServer: isServer,
    );
    _peers[peerDeviceId] = peer;
    _startReadLoop(peer);
    return peerDeviceId;
  }

  bool _preferIncoming(String peerDeviceId) =>
      _identityManager.deviceId.compareTo(peerDeviceId) > 0;

  void _startReadLoop(_NativePeerConnection peer) {
    final chunks = StreamController<List<int>>();
    peer.chunkController = chunks;
    peer.frameSubscription = chunks.stream
        .transform(
      RiftFrameTransformer(
        maxFrameSizeProvider: () =>
            _authenticatedPeers.contains(peer.peerDeviceId)
                ? RiftFrameCodec.maxFrameSizePostAuth
                : RiftFrameCodec.maxFrameSizePreAuth,
      ),
    )
        .listen(
      (frame) {
        if (_peers[peer.peerDeviceId] != peer || _messages.isClosed) return;
        _messages.add(
          TransportMessage(
            peerDeviceId: peer.peerDeviceId,
            payload: Uint8List.fromList(utf8.encode(json.encode(frame))),
            peerEd25519Key: peer.peerEd25519Key,
            peerCertDer: peer.peerCertificateDer,
          ),
        );
      },
      onError: (_) => _handleConnectionClosed(peer),
      onDone: () => _handleConnectionClosed(peer),
      cancelOnError: true,
    );
    unawaited(_readLoop(peer));
  }

  Future<void> _readLoop(_NativePeerConnection peer) async {
    try {
      while (_peers[peer.peerDeviceId] == peer && !_stopping) {
        final result = await AndroidNativeTls.read(peer.connectionId);
        if (result['eof'] == true) break;
        final encoded = result['dataBase64'];
        if (encoded is! String) {
          throw const FormatException('Native TLS read omitted payload data.');
        }
        peer.chunkController?.add(base64.decode(encoded));
      }
    } catch (_) {
      // Connection cleanup below is authoritative.
    }
    await _handleConnectionClosed(peer);
  }

  Future<void> _handleConnectionClosed(_NativePeerConnection peer) async {
    if (_peers[peer.peerDeviceId] != peer) return;
    _peers.remove(peer.peerDeviceId);
    _authenticatedPeers.remove(peer.peerDeviceId);
    await _closeConnection(peer, notify: true);
  }

  Future<void> _closeConnection(
    _NativePeerConnection peer, {
    required bool notify,
  }) async {
    await peer.frameSubscription?.cancel();
    await peer.chunkController?.close();
    try {
      await AndroidNativeTls.close(peer.connectionId);
    } catch (_) {}
    if (notify && !_disconnects.isClosed) {
      _disconnects.add(peer.peerDeviceId);
    }
  }

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    final peer = _peers[deviceId];
    if (peer == null) {
      throw StateError('Peer $deviceId is not connected');
    }
    final frame = RiftFrameCodec.encodeBytes(message);
    await AndroidNativeTls.write(peer.connectionId, base64.encode(frame));
  }

  @override
  void disconnect(String peerDeviceId) {
    final peer = _peers.remove(peerDeviceId);
    _authenticatedPeers.remove(peerDeviceId);
    if (peer != null) {
      unawaited(_closeConnection(peer, notify: true));
    }
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {
    if (_peers.containsKey(peerDeviceId)) {
      _authenticatedPeers.add(peerDeviceId);
    }
  }

  @override
  Uint8List? getPeerCert(String peerDeviceId) =>
      _peers[peerDeviceId]?.peerCertificateDer;

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) {
    final peer = _peers[peerDeviceId];
    if (peer == null) return null;
    return PeerSocketEndpoint(
      address: peer.remoteAddress,
      port: peer.remotePort,
      isServer: peer.isServer,
    );
  }

  @override
  Future<void> stopServer() async {
    _stopping = true;
    final peers = _peers.values.toList(growable: false);
    _peers.clear();
    _authenticatedPeers.clear();
    for (final peer in peers) {
      await _closeConnection(peer, notify: false);
    }
    await AndroidNativeTls.stopServer();
    await _messages.close();
    await _disconnects.close();
  }

  String _derivePeerDeviceId(String certificateBase64) {
    final certDer = Uint8List.fromList(base64.decode(certificateBase64));
    final key = RiftCertDecoder.extractEd25519PublicKeyFromDer(certDer);
    return _deviceIdForKey(key);
  }

  String _deviceIdForKey(Uint8List key) {
    final digest = sha256.convert(key).bytes;
    final encoded = Base32Utils.encode(
      Uint8List.fromList(digest),
    ).toLowerCase();
    return 'rift-${encoded.substring(0, 32)}';
  }
}

class _NativePeerConnection {
  _NativePeerConnection({
    required this.connectionId,
    required this.peerDeviceId,
    required this.peerCertificateDer,
    required this.peerEd25519Key,
    required this.remoteAddress,
    required this.remotePort,
    required this.isServer,
  });

  final int connectionId;
  final String peerDeviceId;
  final Uint8List peerCertificateDer;
  final Uint8List peerEd25519Key;
  final String remoteAddress;
  final int remotePort;
  final bool isServer;
  StreamController<List<int>>? chunkController;
  StreamSubscription<Map<String, dynamic>>? frameSubscription;
}
