import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../crypto/cert_decoder.dart';
import 'frame_codec.dart';

class TransportImpl implements Transport {
  final IdentityManager _identityManager;
  final int port;
  
  SecureServerSocket? _serverSocket;
  final Map<String, SecureSocket> _peers = {};
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
  }

  @override
  Future<void> connectTo(String host, int port) async {
    final context = SecurityContext();
    final certBytes = utf8.encode(_identityManager.tlsCertificatePem);
    final keyBytes = utf8.encode(_identityManager.tlsPrivateKeyPem);
    
    context.useCertificateChainBytes(certBytes);
    context.usePrivateKeyBytes(keyBytes);

    final socket = await SecureSocket.connect(
      host,
      port,
      context: context,
      onBadCertificate: (X509Certificate cert) => true, // Verification is deferred to post-handshake Ed25519 check
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
      final base32Str = _encodeBase32(Uint8List.fromList(hash.bytes)).toLowerCase();
      final peerDeviceId = 'rift-${base32Str.substring(0, 32)}';

      _peers[peerDeviceId] = socket;

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

  /// Simple RFC 4648 Base32 Encoder without padding
  static String _encodeBase32(Uint8List data) {
    const String alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    int buffer = 0;
    int bitsLeft = 0;
    StringBuffer result = StringBuffer();

    for (int i = 0; i < data.length; i++) {
      buffer = (buffer << 8) | data[i];
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        result.write(alphabet[(buffer >> (bitsLeft - 5)) & 0x1F]);
        bitsLeft -= 5;
      }
    }
    if (bitsLeft > 0) {
      result.write(alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }
    return result.toString();
  }
}
