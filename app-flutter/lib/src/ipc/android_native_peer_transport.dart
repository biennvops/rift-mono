import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:daemon_dart/daemon_dart.dart';

import '../platform/android_native_tls.dart';
import 'native_tls_api.dart';

class AndroidNativePeerTransport implements Transport, BoundTransport {
  AndroidNativePeerTransport(
    this._identityManager, {
    required int port,
    NativeTlsApi? tlsApi,
  })  : _requestedPort = port,
        _tls = tlsApi ?? MethodChannelNativeTlsApi();

  final IdentityManager _identityManager;
  final NativeTlsApi _tls;
  final int _requestedPort;
  final Map<String, _NativePeerConnection> _peers = {};
  final Set<String> _authenticatedPeers = {};
  final StreamController<TransportMessage> _messages =
      StreamController<TransportMessage>.broadcast();
  final StreamController<String> _disconnects =
      StreamController<String>.broadcast(sync: true);
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
    _boundPort = await _tls.startServer(
      certificatePem: _identityManager.tlsCertificatePem,
      privateKeyPem: _identityManager.tlsPrivateKeyPem,
      port: _requestedPort,
    );
    unawaited(_acceptLoop());
  }

  Future<void> _acceptLoop() async {
    while (!_stopping) {
      try {
        final connection = await _tls.accept();
        await _registerConnection(connection, isServer: true);
      } catch (_) {
        if (!_stopping) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }

  static bool shouldKeepExistingPreAuthConnection({
    required bool existingIsServer,
    required bool candidateIsServer,
    required bool preferredIsServer,
  }) =>
      existingIsServer == preferredIsServer ||
      candidateIsServer != preferredIsServer;

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

    final connection = await _tls.connect(
      host: host,
      port: port,
      certificatePem: _identityManager.tlsCertificatePem,
      privateKeyPem: _identityManager.tlsPrivateKeyPem,
    );
    final peerDeviceId = _derivePeerDeviceId(connection.peerCertificateBase64);
    if (expectedDeviceId != null &&
        RegExp(r'^rift-[a-z2-7]{32}$').hasMatch(expectedDeviceId) &&
        expectedDeviceId != peerDeviceId) {
      await _tls.close(connection.connectionId);
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
    final wasAuthenticated = _authenticatedPeers.contains(peerDeviceId);

    if (existing != null) {
      if (wasAuthenticated && !isServer) {
        // Our own redundant outbound dial; keep the authenticated session.
        await _tls.close(connection.connectionId);
        return peerDeviceId;
      }
      if (!wasAuthenticated) {
        final preferredIsServer =
            _identityManager.deviceId.compareTo(peerDeviceId) > 0;
        if (shouldKeepExistingPreAuthConnection(
          existingIsServer: existing.isServer,
          candidateIsServer: isServer,
          preferredIsServer: preferredIsServer,
        )) {
          await _tls.close(connection.connectionId);
          return peerDeviceId;
        }
      }
    }
    // A fresh inbound connection from an authenticated peer means its side
    // of the old socket is dead (mobile apps are killed/suspended without a
    // clean TCP close), so the newcomer must replace the stale session.

    final peer = _NativePeerConnection(
      connectionId: connection.connectionId,
      peerDeviceId: peerDeviceId,
      peerCertificateDer: certDer,
      peerEd25519Key: peerEd25519Key,
      remoteAddress: connection.remoteAddress,
      remotePort: connection.remotePort,
      isServer: isServer,
    );
    // Install the replacement before tearing down a stale pre-auth
    // connection: the old read loop's failure callback must observe the new
    // owner in _peers so it neither removes the entry nor emits a disconnect
    // for the peer we are actively replacing.
    _peers[peerDeviceId] = peer;
    if (existing != null) {
      _authenticatedPeers.remove(peerDeviceId);
      if (wasAuthenticated) {
        // Reset the old session before the replacement can start its
        // handshake. The old socket is closed silently below so its teardown
        // cannot remove the replacement session.
        resetSessionForReplacement(peerDeviceId);
      }
      await _closeConnection(existing, notify: false);
    }
    _startReadLoop(peer);
    return peerDeviceId;
  }

  @visibleForTesting
  void resetSessionForReplacement(String peerDeviceId) {
    if (!_disconnects.isClosed) {
      _disconnects.add(peerDeviceId);
    }
  }

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
        final result = await _tls.read(peer.connectionId);
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
      await _tls.close(peer.connectionId);
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
    await _tls.write(peer.connectionId, base64.encode(frame));
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
    await _tls.stopServer();
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
