import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../core/rift_exceptions.dart';
import '../core/rift_log.dart';
import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../crypto/cert_decoder.dart';
import '../crypto/base32_utils.dart';
import 'frame_codec.dart';
import 'peer_write_gate.dart';

class TransportImpl implements Transport {
  final IdentityManager _identityManager;
  final int port;

  SecureServerSocket? _serverSocket;
  final Map<String, SecureSocket> _peers = {};
  final Map<String, bool> _peerSocketIsServer = {};
  final Map<String, Uint8List> _peerCerts = {};
  final Map<String, PeerWriteGate> _peerWriteGates = {};
  final Set<String> _authenticatedPeers = {};
  final Map<String, Timer> _unauthenticatedTimeouts = {};
  final _messageController = StreamController<TransportMessage>.broadcast();
  final _disconnectController = StreamController<String>.broadcast(sync: true);

  TransportImpl(this._identityManager, {required this.port});

  int get boundPort => _serverSocket?.port ?? port;

  @override
  Future<void> startServer() async {
    final context = SecurityContext();
    final certBytes = utf8.encode(_identityManager.tlsCertificatePem);
    final keyBytes = utf8.encode(_identityManager.tlsPrivateKeyPem);

    context.useCertificateChainBytes(certBytes);
    context.usePrivateKeyBytes(keyBytes);

    _serverSocket = await SecureServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      context,
      requestClientCertificate: true,
      // Dart's TLS server stack rejects self-signed client certificates before
      // application code can inspect them when requireClientCertificate=true.
      // Rift authenticates peers with the embedded Ed25519 identity + PoP
      // during session bootstrap, so we request the client cert here and fail
      // closed below if the peer omits it or later fails PoP/session checks.
      requireClientCertificate: false,
    );

    _serverSocket!.listen(
      (socket) {
        unawaited(() async {
          try {
            await _handleConnection(socket, isServer: true);
          } catch (error) {
            RiftLog.debug(
              '[TLS] Inbound connection setup finished with a handled error: $error',
            );
          }
        }());
      },
      onError: (Object error, StackTrace stackTrace) {
        RiftLog.error(
          '[TLS] Inbound server handshake failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
      cancelOnError: false,
    );
  }

  @override
  Future<void> stopServer() async {
    await _serverSocket?.close();
    _serverSocket = null;
    for (final timer in _unauthenticatedTimeouts.values) {
      timer.cancel();
    }
    _unauthenticatedTimeouts.clear();
    for (final socket in _peers.values) {
      // Flush before closing to avoid dropping frames written by sendMessage() concurrently.
      try {
        await socket.flush();
      } on SocketException {
        // Best-effort flush during teardown; the socket is being closed anyway.
      }
      await socket.close();
    }
    _peers.clear();
    _peerCerts.clear();
    _peerWriteGates.clear();
    await _messageController.close();
    await _disconnectController.close();
  }

  @override
  Future<String> connectTo(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceFreshSession = false,
  }) async {
    RiftLog.debug(
      '[TLS] connectTo host=$host port=$port '
      'expectedDeviceId=${expectedDeviceId ?? "<none>"} '
      'forceFreshSession=$forceFreshSession',
    );
    final context = SecurityContext();
    final certBytes = utf8.encode(_identityManager.tlsCertificatePem);
    final keyBytes = utf8.encode(_identityManager.tlsPrivateKeyPem);

    context.useCertificateChainBytes(certBytes);
    context.usePrivateKeyBytes(keyBytes);

    final socket = await SecureSocket.connect(
      host,
      port,
      context: context,
      onBadCertificate: (X509Certificate cert) {
        if (expectedDeviceId != null) {
          try {
            final peerEd25519Key = RiftCertDecoder.extractEd25519PublicKey(
              cert.pem,
            );
            final hash = sha256.convert(peerEd25519Key);
            final base32Str = Base32Utils.encode(
              Uint8List.fromList(hash.bytes),
            ).toLowerCase();
            final actualDeviceId = 'rift-${base32Str.substring(0, 32)}';
            RiftLog.debug(
              '[TLS] peer cert check host=$host port=$port actualDeviceId=$actualDeviceId expectedDeviceId=$expectedDeviceId',
            );
            // Only enforce strict pinning if expectedDeviceId is a real device ID (matches regex)
            final isRealDeviceId = RegExp(
              r'^rift-[a-z2-7]{32}$',
            ).hasMatch(expectedDeviceId);
            if (isRealDeviceId && actualDeviceId != expectedDeviceId) {
              RiftLog.warn(
                '[TLS] Device ID mismatch during TLS pinning. Rejecting certificate.',
              );
              return false; // Reject MITM immediately during TLS handshake
            }
          } on CertificateDecoderException catch (e) {
            RiftLog.warn(
              '[TLS] Certificate decoder exception while validating peer cert from $host:$port: $e',
            );
            return false; // Fail-closed on invalid cert
          } catch (e) {
            RiftLog.warn(
              '[TLS] Unknown error in onBadCertificate for $host:$port: $e',
            );
            return false;
          }
        }
        // Intentional deferral: when expectedDeviceId is null (e.g. incoming
        // connections) we cannot pin the cert at TLS time. The peer MUST still
        // pass session.hello PoP verification in SessionManager before any
        // protected operation is permitted. The 10-second handshake timeout in
        // _handleConnection limits the window for unauthenticated connections.
        return true;
      },
    );

    return _handleConnection(
      socket,
      isServer: false,
      forceFreshSession: forceFreshSession,
    );
  }

  Future<String> _handleConnection(
    SecureSocket socket, {
    required bool isServer,
    bool forceFreshSession = false,
  }) async {
    final peerCert = socket.peerCertificate;
    if (peerCert == null) {
      socket.destroy();
      throw const RiftAuthenticationFailedException('Peer certificate missing');
    }

    try {
      final peerEd25519Key = RiftCertDecoder.extractEd25519PublicKey(
        peerCert.pem,
      );
      final hash = sha256.convert(peerEd25519Key);
      final base32Str = Base32Utils.encode(
        Uint8List.fromList(hash.bytes),
      ).toLowerCase();
      final peerDeviceId = 'rift-${base32Str.substring(0, 32)}';
      RiftLog.info(
        '[TLS] TLS session established with peerDeviceId=$peerDeviceId host=${socket.remoteAddress.address}:${socket.remotePort}',
      );

      final previousSocket = _peers[peerDeviceId];
      final previousIsServer = _peerSocketIsServer[peerDeviceId];
      if (previousSocket != null &&
          previousIsServer != null &&
          !identical(previousSocket, socket)) {
        if (_authenticatedPeers.contains(peerDeviceId)) {
          RiftLog.info(
            '[TLS] Replacing existing authenticated session for '
            'peerDeviceId=$peerDeviceId with a fresh connection (likely a stale reconnect).',
          );
          disconnect(peerDeviceId);
        } else {
          final preferredIsServer = _preferIncomingSocketForPeer(peerDeviceId);
          if (previousIsServer == preferredIsServer) {
            RiftLog.warn(
              '[TLS] Peer $peerDeviceId reconnected using the preferred role. '
              'The existing pre-auth socket is likely stale. Replacing it.',
            );
            try {
              previousSocket.destroy();
            } catch (_) {}
            // Do not destroy the new socket! We must accept the new connection
            // because the peer initiated it, implying their side of the old connection is dead.
          } else {
            RiftLog.debug(
              '[TLS] Replacing pre-auth socket for peerDeviceId=$peerDeviceId '
              'preferredRole=${preferredIsServer ? "inbound" : "outbound"} '
              'existingRole=${previousIsServer ? "inbound" : "outbound"} '
              'replacementRole=${isServer ? "inbound" : "outbound"}',
            );
            try {
              previousSocket.destroy();
            } catch (_) {
              // Best-effort cleanup while switching to the preferred bootstrap path.
            }
          }
        }
      }

      _peers[peerDeviceId] = socket;
      _peerSocketIsServer[peerDeviceId] = isServer;
      _peerCerts[peerDeviceId] = peerCert.der;
      _peerWriteGates.putIfAbsent(peerDeviceId, PeerWriteGate.new);
      RiftLog.info(
        '[TLS] Registered socket for peerDeviceId=$peerDeviceId role=${isServer ? "inbound" : "outbound"}',
      );

      int frameSizeProvider() {
        return _authenticatedPeers.contains(peerDeviceId)
            ? RiftFrameCodec.maxFrameSizePostAuth
            : RiftFrameCodec.maxFrameSizePreAuth;
      }

      socket
          .cast<List<int>>()
          .transform(
            RiftFrameTransformer(maxFrameSizeProvider: frameSizeProvider),
          )
          .listen(
            (frameJson) {
              _messageController.add(
                TransportMessage(
                  peerDeviceId: peerDeviceId,
                  payload: Uint8List.fromList(
                    utf8.encode(json.encode(frameJson)),
                  ),
                  peerEd25519Key: peerEd25519Key,
                  peerCertDer: peerCert.der,
                ),
              );
            },
            onError: (e) {
              _disconnectIfCurrent(peerDeviceId, socket);
            },
            onDone: () {
              _disconnectIfCurrent(peerDeviceId, socket);
            },
            cancelOnError: true,
          );

      // Disconnect unauthenticated peers after 10 s to prevent connection-slot exhaustion.
      _unauthenticatedTimeouts[peerDeviceId]?.cancel();
      _unauthenticatedTimeouts[peerDeviceId] = Timer(
        const Duration(seconds: 10),
        () {
          if (identical(_peers[peerDeviceId], socket) &&
              !_authenticatedPeers.contains(peerDeviceId)) {
            RiftLog.warn(
              '[TLS] Closing unauthenticated peer after timeout peerDeviceId=$peerDeviceId role=${isServer ? "inbound" : "outbound"}',
            );
            disconnect(peerDeviceId);
          }
        },
      );

      return peerDeviceId;
    } catch (e) {
      // Fail-closed: destroy socket if cert is missing the Rift extension.
      socket.destroy();
      rethrow;
    }
  }

  @override
  void disconnect(String peerDeviceId) {
    RiftLog.debug(
      '[TLS] disconnect(peerDeviceId=$peerDeviceId) authenticated=${_authenticatedPeers.contains(peerDeviceId)} '
      'role=${_peerSocketIsServer[peerDeviceId] == true
          ? "inbound"
          : _peerSocketIsServer.containsKey(peerDeviceId)
          ? "outbound"
          : "unknown"}',
    );
    _unauthenticatedTimeouts.remove(peerDeviceId)?.cancel();
    _peers[peerDeviceId]?.destroy();
    _peers.remove(peerDeviceId);
    _peerSocketIsServer.remove(peerDeviceId);
    _peerCerts.remove(peerDeviceId);
    _peerWriteGates.remove(peerDeviceId);
    _authenticatedPeers.remove(peerDeviceId);
    if (!_disconnectController.isClosed) {
      _disconnectController.add(peerDeviceId);
    }
  }

  void _disconnectIfCurrent(String peerDeviceId, SecureSocket socket) {
    if (!identical(_peers[peerDeviceId], socket)) {
      RiftLog.debug(
        '[TLS] Ignoring disconnect from stale socket for peerDeviceId=$peerDeviceId '
        'socket=${socket.remoteAddress.address}:${socket.remotePort}',
      );
      try {
        socket.destroy();
      } catch (_) {
        // Best-effort cleanup for a stale socket that no longer owns the mapping.
      }
      return;
    }

    disconnect(peerDeviceId);
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {
    if (_peers.containsKey(peerDeviceId)) {
      _unauthenticatedTimeouts.remove(peerDeviceId)?.cancel();
      _authenticatedPeers.add(peerDeviceId);
    }
  }

  @override
  Stream<TransportMessage> get onMessageReceived => _messageController.stream;

  @override
  Stream<String> get onPeerDisconnected => _disconnectController.stream;

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    final socket = _peers[deviceId];
    if (socket == null) {
      throw StateError('Peer $deviceId is not connected');
    }
    final writeGate = _peerWriteGates.putIfAbsent(deviceId, PeerWriteGate.new);
    RiftLog.info(
      '[TLS] transport.sendMessage peerDeviceId=$deviceId '
      'bytes=${message.length} remote=${socket.remoteAddress.address}:${socket.remotePort}',
    );

    // Validate outbound payload once, then frame the original bytes without re-encoding.
    try {
      final jsonStr = utf8.decode(message);
      final decoded = json.decode(jsonStr);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Outbound payload must be a JSON object');
      }
    } on FormatException {
      disconnect(deviceId);
      rethrow;
    }

    // Avoid double JSON serialization overhead:
    // - we already have `message` (UTF-8 JSON bytes)
    // - framing only needs the length prefix
    final frame = RiftFrameCodec.encodeBytes(message);
    try {
      await writeGate.run(() async {
        final currentSocket = _peers[deviceId];
        if (currentSocket == null || !identical(currentSocket, socket)) {
          throw StateError(
            'Peer $deviceId is no longer connected on the current socket',
          );
        }

        currentSocket.add(frame);
        await currentSocket.flush();
        RiftLog.info(
          '[TLS] transport.sendMessage flushed peerDeviceId=$deviceId',
        );
      });
    } on SocketException {
      disconnect(deviceId);
      rethrow;
    } on StateError {
      disconnect(deviceId);
      rethrow;
    }
  }

  @override
  Uint8List? getPeerCert(String peerDeviceId) => _peerCerts[peerDeviceId];

  @override
  PeerSocketEndpoint? getPeerSocketEndpoint(String peerDeviceId) {
    final socket = _peers[peerDeviceId];
    if (socket == null) {
      return null;
    }

    return PeerSocketEndpoint(
      address: socket.remoteAddress.address,
      port: socket.remotePort,
      isServer: _peerSocketIsServer[peerDeviceId] ?? false,
    );
  }

  bool _preferIncomingSocketForPeer(String peerDeviceId) {
    final localDeviceId = _identityManager.deviceId;
    return localDeviceId.compareTo(peerDeviceId) > 0;
  }
}
