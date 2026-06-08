import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../crypto/cert_decoder.dart';
import '../crypto/base32_utils.dart';
import 'frame_codec.dart';

class TransportImpl implements Transport {
  final IdentityManager _identityManager;
  final int port;
  
  SecureServerSocket? _serverSocket;
  final Map<String, SecureSocket> _peers = {};
  final Map<String, Uint8List> _peerCerts = {};
  final Set<String> _authenticatedPeers = {};
  final _messageController = StreamController<TransportMessage>.broadcast();

  TransportImpl(this._identityManager, {required this.port});

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
      requireClientCertificate: true,
    );

    _serverSocket!.listen((socket) => _handleConnection(socket, isServer: true));
  }

  @override
  Future<void> stopServer() async {
    await _serverSocket?.close();
    _serverSocket = null;
    for (final socket in _peers.values) {
      await socket.close();
    }
    _peers.clear();
    _peerCerts.clear();
    await _messageController.close();
  }

  @override
  Future<void> connectTo(String host, int port, {String? expectedDeviceId}) async {
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
            final peerEd25519Key = RiftCertDecoder.extractEd25519PublicKey(cert.pem);
            final hash = sha256.convert(peerEd25519Key);
            final base32Str = Base32Utils.encode(Uint8List.fromList(hash.bytes)).toLowerCase();
            final actualDeviceId = 'rift-${base32Str.substring(0, 32)}';
            if (actualDeviceId != expectedDeviceId) {
              return false; // Reject MITM immediately during TLS handshake
            }
          } catch (_) {
            return false; // Fail-closed on invalid cert
          }
        }
        return true; // Defer to post-handshake if expectedDeviceId is not provided
      },
    );

    _handleConnection(socket, isServer: false);
  }

  void _handleConnection(SecureSocket socket, {required bool isServer}) async {
    final peerCert = socket.peerCertificate;
    if (peerCert == null) {
      socket.destroy();
      return;
    }

    try {
      // RIsk 3 Enforced: Identity is STRICTLY extracted from the Certificate, not the payload!
      final peerEd25519Key = RiftCertDecoder.extractEd25519PublicKey(peerCert.pem);
      
      // Compute expected peer device ID based on the key
      final hash = sha256.convert(peerEd25519Key);
      final base32Str = Base32Utils.encode(Uint8List.fromList(hash.bytes)).toLowerCase();
      final peerDeviceId = 'rift-${base32Str.substring(0, 32)}';

      _peers[peerDeviceId] = socket;
      _peerCerts[peerDeviceId] = peerCert.der;

      int frameSizeProvider() {
        return _authenticatedPeers.contains(peerDeviceId) 
            ? RiftFrameCodec.maxFrameSizePostAuth 
            : RiftFrameCodec.maxFrameSizePreAuth;
      }

      socket.cast<List<int>>().transform(RiftFrameTransformer(maxFrameSizeProvider: frameSizeProvider)).listen(
        (frameJson) {
          _messageController.add(TransportMessage(
            peerDeviceId: peerDeviceId,
            payload: Uint8List.fromList(utf8.encode(json.encode(frameJson))),
            peerEd25519Key: peerEd25519Key,
            peerCertDer: peerCert.der,
          ));
        },
        onError: (e) {
          disconnect(peerDeviceId);
        },
        onDone: () {
          disconnect(peerDeviceId);
        },
        cancelOnError: true,
      );

      // Handshake Timeout: Mitigate connection slot exhaustion
      Timer(const Duration(seconds: 10), () {
        if (_peers.containsKey(peerDeviceId) && !_authenticatedPeers.contains(peerDeviceId)) {
          disconnect(peerDeviceId); // Timeout reached, peer hasn't authenticated
        }
      });

    } catch (e) {
      // Invalid cert or missing extension -> Fail-Closed Authentication
      socket.destroy();
    }
  }

  @override
  void disconnect(String peerDeviceId) {
    _peers[peerDeviceId]?.destroy();
    _peers.remove(peerDeviceId);
    _peerCerts.remove(peerDeviceId);
    _authenticatedPeers.remove(peerDeviceId);
  }

  @override
  void setPeerAuthenticated(String peerDeviceId) {
    if (_peers.containsKey(peerDeviceId)) {
      _authenticatedPeers.add(peerDeviceId);
    }
  }

  @override
  Stream<TransportMessage> get onMessageReceived => _messageController.stream;

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    final socket = _peers[deviceId];
    if (socket != null) {
      try {
        final jsonStr = utf8.decode(message);
        final jsonMap = json.decode(jsonStr) as Map<String, dynamic>;
        final frame = RiftFrameCodec.encode(jsonMap);
        socket.add(frame);
        await socket.flush();
      } catch (e) {
        // Encoding errors or closed socket
        disconnect(deviceId);
      }
    }
  }

  @override
  Uint8List? getPeerCert(String peerDeviceId) => _peerCerts[peerDeviceId];
}
