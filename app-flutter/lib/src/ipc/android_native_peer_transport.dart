import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:daemon_dart/daemon_dart.dart';

import '../platform/android_native_tls.dart';
import 'native_tls_api.dart';

class AndroidNativePeerTransport
    implements
        Transport,
        BoundTransport,
        PendingCandidateTransport,
        ConnectionScopedTransport {
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
  final Map<String, _NativePeerConnection> _pendingCandidates = {};
  final Map<String, Future<void>> _peerWriteTails = {};
  final StreamController<TransportMessage> _messages =
      StreamController<TransportMessage>.broadcast();
  final StreamController<String> _disconnects =
      StreamController<String>.broadcast(sync: true);
  final StreamController<TransportDisconnect> _connectionDisconnects =
      StreamController<TransportDisconnect>.broadcast(sync: true);
  bool _stopping = false;
  int _boundPort = 0;

  @override
  int get boundPort => _boundPort;

  @override
  Stream<TransportMessage> get onMessageReceived => _messages.stream;

  @override
  Stream<String> get onPeerDisconnected => _disconnects.stream;

  @override
  Stream<TransportDisconnect> get onConnectionDisconnected =>
      _connectionDisconnects.stream;

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
    final wasAuthenticated = existing?.authenticated ?? false;

    if (existing != null) {
      if (wasAuthenticated) {
        if (!isServer) {
          // Our own redundant outbound dial; keep the authenticated session.
          await _tls.close(connection.connectionId);
          return peerDeviceId;
        }

        // A TLS connection does not prove that the peer's endpoint lookup was
        // for this device. A stale trusted endpoint can connect to a different
        // device at the same address, then close before sending session.hello.
        // Keep the established session until the inbound candidate proves it
        // is a valid replacement at the protocol layer.
        return _registerAuthenticatedCandidate(
          connection,
          peerDeviceId: peerDeviceId,
          certDer: certDer,
          peerEd25519Key: peerEd25519Key,
          isServer: isServer,
        );
      }

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

    final peer = _createPeer(
      connection,
      peerDeviceId: peerDeviceId,
      certDer: certDer,
      peerEd25519Key: peerEd25519Key,
      isServer: isServer,
    );
    _peers[peerDeviceId] = peer;
    if (existing != null) {
      await _closeConnection(
        existing,
        notify: false,
        waitForStreamTeardown: false,
      );
    }
    _startAuthenticationTimeout(peer);
    _startReadLoop(peer);
    return peerDeviceId;
  }

  String _registerAuthenticatedCandidate(
    AndroidTlsConnection connection, {
    required String peerDeviceId,
    required Uint8List certDer,
    required Uint8List peerEd25519Key,
    required bool isServer,
  }) {
    final candidate = _createPeer(
      connection,
      peerDeviceId: peerDeviceId,
      certDer: certDer,
      peerEd25519Key: peerEd25519Key,
      isServer: isServer,
    )..pendingCandidate = true;
    final previous = _pendingCandidates[peerDeviceId];
    _pendingCandidates[peerDeviceId] = candidate;
    if (previous != null) {
      unawaited(_closeConnection(previous, notify: false));
    }
    _startAuthenticationTimeout(candidate);
    _startReadLoop(candidate);
    return peerDeviceId;
  }

  _NativePeerConnection _createPeer(
    AndroidTlsConnection connection, {
    required String peerDeviceId,
    required Uint8List certDer,
    required Uint8List peerEd25519Key,
    required bool isServer,
  }) =>
      _NativePeerConnection(
        connectionId: connection.connectionId,
        peerDeviceId: peerDeviceId,
        peerCertificateDer: certDer,
        peerEd25519Key: peerEd25519Key,
        remoteAddress: connection.remoteAddress,
        remotePort: connection.remotePort,
        isServer: isServer,
      );

  void _startAuthenticationTimeout(_NativePeerConnection peer) {
    peer.authenticationTimeout = Timer(const Duration(seconds: 10), () {
      if (peer.pendingCandidate) {
        if (identical(_pendingCandidates[peer.peerDeviceId], peer)) {
          _pendingCandidates.remove(peer.peerDeviceId);
          unawaited(_closeConnection(peer, notify: false));
        }
      } else if (identical(_peers[peer.peerDeviceId], peer) &&
          !peer.authenticated) {
        disconnectConnection(peer.peerDeviceId, peer);
      }
    });
  }

  void _handleCandidateFrame(
    _NativePeerConnection candidate,
    Map<String, dynamic> frame,
  ) {
    final peerDeviceId = candidate.peerDeviceId;
    if (!identical(_pendingCandidates[peerDeviceId], candidate)) {
      return;
    }
    if (frame['type'] != 'session.hello') {
      _pendingCandidates.remove(peerDeviceId);
      unawaited(_closeConnection(candidate, notify: false));
      return;
    }

    if (candidate.helloPendingValidation) {
      _pendingCandidates.remove(peerDeviceId);
      unawaited(_closeConnection(candidate, notify: false));
      return;
    }
    candidate.helloPendingValidation = true;
    _messages.add(_transportMessage(candidate, frame));
  }

  TransportMessage _transportMessage(
    _NativePeerConnection peer,
    Map<String, dynamic> frame,
  ) =>
      TransportMessage(
        peerDeviceId: peer.peerDeviceId,
        payload: Uint8List.fromList(utf8.encode(json.encode(frame))),
        peerEd25519Key: peer.peerEd25519Key,
        peerCertDer: peer.peerCertificateDer,
        connectionToken: peer,
        pendingCandidate: peer.pendingCandidate,
      );

  @visibleForTesting
  void injectConnectionForTesting({
    required String peerDeviceId,
    required int connectionId,
    StreamSubscription<Map<String, dynamic>>? frameSubscription,
    bool isServer = false,
    bool authenticated = false,
  }) {
    _peers[peerDeviceId] = _NativePeerConnection(
      connectionId: connectionId,
      peerDeviceId: peerDeviceId,
      peerCertificateDer: Uint8List(0),
      peerEd25519Key: Uint8List(0),
      remoteAddress: '127.0.0.1',
      remotePort: 0,
      isServer: isServer,
    )
      ..frameSubscription = frameSubscription
      ..authenticated = authenticated;
  }

  @visibleForTesting
  void injectPendingCandidateForTesting({
    required String peerDeviceId,
    required int connectionId,
  }) {
    _pendingCandidates[peerDeviceId] = _NativePeerConnection(
      connectionId: connectionId,
      peerDeviceId: peerDeviceId,
      peerCertificateDer: Uint8List(0),
      peerEd25519Key: Uint8List(0),
      remoteAddress: '127.0.0.1',
      remotePort: 0,
      isServer: true,
    )..pendingCandidate = true;
  }

  @visibleForTesting
  Future<void> closePendingCandidateForTesting(String peerDeviceId) async {
    final candidate = _pendingCandidates[peerDeviceId];
    if (candidate != null) {
      await _handleConnectionClosed(candidate);
    }
  }

  @visibleForTesting
  int frameSizeLimitForTesting(int connectionId) {
    final peer = <_NativePeerConnection>[
      ..._peers.values,
      ..._pendingCandidates.values,
    ].singleWhere((candidate) => candidate.connectionId == connectionId);
    return _maxFrameSizeForPeer(peer);
  }

  @visibleForTesting
  void acceptPendingCandidateHelloForTesting(String peerDeviceId) {
    final candidate = _pendingCandidates[peerDeviceId];
    if (candidate != null) {
      _handleCandidateFrame(candidate, const {'type': 'session.hello'});
    }
  }

  @visibleForTesting
  Future<void> closeConnectionForReplacementForTesting(
    String peerDeviceId,
  ) async {
    final peer = _peers[peerDeviceId];
    if (peer != null) {
      await _closeConnection(
        peer,
        notify: false,
        waitForStreamTeardown: false,
      );
    }
  }

  @override
  Future<bool> promotePendingCandidate(TransportMessage message) async {
    final candidate = message.connectionToken;
    if (candidate is! _NativePeerConnection ||
        !identical(_pendingCandidates[message.peerDeviceId], candidate)) {
      return false;
    }

    final peerDeviceId = message.peerDeviceId;
    final existing = _peers[peerDeviceId];
    _pendingCandidates.remove(peerDeviceId);
    candidate.pendingCandidate = false;
    candidate.helloPendingValidation = false;
    if (existing != null &&
        shouldKeepExistingPreAuthConnection(
          existingIsServer: existing.isServer,
          candidateIsServer: candidate.isServer,
          preferredIsServer:
              _identityManager.deviceId.compareTo(peerDeviceId) > 0,
        )) {
      await _closeConnection(candidate, notify: false);
      return false;
    }

    _peers[peerDeviceId] = candidate;
    if (existing != null && !identical(existing, candidate)) {
      await _closeConnection(
        existing,
        notify: false,
        waitForStreamTeardown: false,
      );
    }
    return true;
  }

  @override
  Future<void> rejectPendingCandidate(TransportMessage message) async {
    final candidate = message.connectionToken;
    if (candidate is! _NativePeerConnection ||
        !identical(_pendingCandidates[message.peerDeviceId], candidate)) {
      return;
    }
    _pendingCandidates.remove(message.peerDeviceId);
    await _closeConnection(candidate, notify: false);
  }

  int _maxFrameSizeForPeer(_NativePeerConnection peer) => peer.authenticated
      ? RiftFrameCodec.maxFrameSizePostAuth
      : RiftFrameCodec.maxFrameSizePreAuth;

  void _startReadLoop(_NativePeerConnection peer) {
    final chunks = StreamController<List<int>>();
    peer.chunkController = chunks;
    peer.frameSubscription = chunks.stream
        .transform(
      RiftFrameTransformer(
        maxFrameSizeProvider: () => _maxFrameSizeForPeer(peer),
      ),
    )
        .listen(
      (frame) {
        if (peer.pendingCandidate) {
          _handleCandidateFrame(peer, frame);
          return;
        }
        if (_peers[peer.peerDeviceId] != peer || _messages.isClosed) return;
        _messages.add(_transportMessage(peer, frame));
      },
      onError: (_) => _handleConnectionClosed(
        peer,
        fromFrameSubscription: true,
      ),
      onDone: () => _handleConnectionClosed(
        peer,
        fromFrameSubscription: true,
      ),
      cancelOnError: true,
    );
    unawaited(_readLoop(peer));
  }

  Future<void> _readLoop(_NativePeerConnection peer) async {
    try {
      while ((_peers[peer.peerDeviceId] == peer ||
              _pendingCandidates[peer.peerDeviceId] == peer) &&
          !_stopping) {
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

  Future<void> _handleConnectionClosed(
    _NativePeerConnection peer, {
    bool fromFrameSubscription = false,
  }) async {
    if (identical(_pendingCandidates[peer.peerDeviceId], peer)) {
      _pendingCandidates.remove(peer.peerDeviceId);
      await _closeConnection(
        peer,
        notify: false,
        cancelFrameSubscription: !fromFrameSubscription,
      );
      return;
    }
    if (_peers[peer.peerDeviceId] != peer) return;
    _peers.remove(peer.peerDeviceId);
    await _closeConnection(
      peer,
      notify: true,
      cancelFrameSubscription: !fromFrameSubscription,
    );
  }

  Future<void> _closeConnection(
    _NativePeerConnection peer, {
    required bool notify,
    bool cancelFrameSubscription = true,
    bool waitForStreamTeardown = true,
  }) async {
    if (peer.isClosing) {
      return;
    }
    peer.isClosing = true;
    peer.authenticationTimeout?.cancel();
    try {
      await _tls.close(peer.connectionId);
    } catch (_) {}
    if (notify) {
      if (!_connectionDisconnects.isClosed) {
        _connectionDisconnects.add(
          TransportDisconnect(
            peerDeviceId: peer.peerDeviceId,
            connectionToken: peer,
          ),
        );
      }
      if (!_disconnects.isClosed) {
        _disconnects.add(peer.peerDeviceId);
      }
    }
    final streamTeardown = _tearDownConnectionStreams(
      peer,
      cancelFrameSubscription: cancelFrameSubscription,
    );
    if (waitForStreamTeardown) {
      await streamTeardown;
    } else {
      unawaited(streamTeardown);
    }
  }

  Future<void> _tearDownConnectionStreams(
    _NativePeerConnection peer, {
    required bool cancelFrameSubscription,
  }) async {
    if (cancelFrameSubscription) {
      try {
        await peer.frameSubscription?.cancel();
      } catch (_) {}
    }
    try {
      await peer.chunkController?.close();
    } catch (_) {}
  }

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    final peer = _peers[deviceId];
    if (peer == null) {
      throw StateError('Peer $deviceId is not connected');
    }
    final frame = RiftFrameCodec.encodeBytes(message);
    final previous = _peerWriteTails[deviceId] ?? Future<void>.value();
    final next = previous.then((_) async {
      final currentPeer = _peers[deviceId];
      if (!identical(currentPeer, peer)) {
        throw StateError(
          'Peer $deviceId is no longer connected on this socket',
        );
      }
      await _tls.write(peer.connectionId, base64.encode(frame));
    });
    late final Future<void> tail;
    tail = next.catchError((_) {}).whenComplete(() {
      if (identical(_peerWriteTails[deviceId], tail)) {
        _peerWriteTails.remove(deviceId);
      }
    });
    _peerWriteTails[deviceId] = tail;
    await next;
  }

  @override
  Object? currentConnectionToken(String peerDeviceId) => _peers[peerDeviceId];

  @override
  bool isCurrentConnection(
    String peerDeviceId,
    Object? connectionToken,
  ) =>
      connectionToken != null &&
      identical(_peers[peerDeviceId], connectionToken);

  @override
  void disconnectConnection(
    String peerDeviceId,
    Object? connectionToken,
  ) {
    if (connectionToken is! _NativePeerConnection ||
        connectionToken.peerDeviceId != peerDeviceId) {
      return;
    }
    if (identical(_peers[peerDeviceId], connectionToken)) {
      _peers.remove(peerDeviceId);
      unawaited(_closeConnection(connectionToken, notify: true));
      return;
    }
    if (identical(_pendingCandidates[peerDeviceId], connectionToken)) {
      _pendingCandidates.remove(peerDeviceId);
    }
    unawaited(_closeConnection(connectionToken, notify: false));
  }

  @override
  void disconnect(String peerDeviceId) {
    final peer = _peers.remove(peerDeviceId);
    final candidate = _pendingCandidates.remove(peerDeviceId);
    if (peer != null) {
      unawaited(_closeConnection(peer, notify: true));
    }
    if (candidate != null) {
      unawaited(_closeConnection(candidate, notify: false));
    }
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {
    final peer = _peers[peerDeviceId];
    if (peer != null) {
      peer.authenticationTimeout?.cancel();
      peer.authenticated = true;
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
    final peers = <_NativePeerConnection>{
      ..._peers.values,
      ..._pendingCandidates.values,
    }.toList(growable: false);
    _peers.clear();
    _pendingCandidates.clear();
    for (final peer in peers) {
      await _closeConnection(peer, notify: false);
    }
    await _tls.stopServer();
    _peerWriteTails.clear();
    await _messages.close();
    await _disconnects.close();
    await _connectionDisconnects.close();
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
  bool pendingCandidate = false;
  bool helloPendingValidation = false;
  bool authenticated = false;
  StreamController<List<int>>? chunkController;
  StreamSubscription<Map<String, dynamic>>? frameSubscription;
  Timer? authenticationTimeout;
  bool isClosing = false;
}
