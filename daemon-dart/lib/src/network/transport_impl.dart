// lib/src/network/transport_impl.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:basic_utils/basic_utils.dart';

import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../crypto/cert_builder.dart';
import '../crypto/cert_decoder.dart';
import 'frame_codec.dart';

class TransportImpl implements Transport {
  final IdentityManager _identityManager;
  final int _port;
  
  SecureServerSocket? _serverSocket;
  final List<SecureSocket> _activeSockets = [];
  final StreamController<dynamic> _messageController = StreamController<dynamic>.broadcast();
  
  late SecurityContext _securityContext;

  TransportImpl(this._identityManager, this._port);

  @override
  Stream<dynamic> get onMessageReceived => _messageController.stream;

  Future<void> initialize() async {
    // Generate ephemeral ECDSA P-256 key pair
    var ecdsaKeyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    var ed25519PubKey = _identityManager.getEd25519PublicKey();

    // Generate Rift-compliant self-signed certificate
    String certPem = RiftCertBuilder.generateSelfSignedCert(ecdsaKeyPair, ed25519PubKey);
    String keyPem = CryptoUtils.encodeEcPrivateKeyToPem(ecdsaKeyPair.privateKey as ECPrivateKey);

    // Setup SecurityContext
    _securityContext = SecurityContext();
    _securityContext.useCertificateChainBytes(utf8.encode(certPem));
    _securityContext.usePrivateKeyBytes(utf8.encode(keyPem));
  }

  @override
  Future<void> startServer() async {
    _serverSocket = await SecureServerSocket.bind(
      InternetAddress.anyIPv4,
      _port,
      _securityContext,
      requestClientCertificate: true,
      requireClientCertificate: true,
    );

    _serverSocket!.listen((SecureSocket socket) {
      _handleNewConnection(socket);
    });
  }

  @override
  Future<void> connectTo(String host, int port) async {
    var socket = await SecureSocket.connect(
      host,
      port,
      context: _securityContext,
      onBadCertificate: (X509Certificate cert) {
        // Provisionally accept self-signed certificates to extract Ed25519 extension.
        return true;
      },
    );
    _handleNewConnection(socket);
  }

  void _handleNewConnection(SecureSocket socket) {
    var peerCert = socket.peerCertificate;
    if (peerCert == null) {
      socket.destroy();
      return;
    }

    try {
      // Post-handshake Ed25519 extraction via Fail-Closed parser
      // Will throw if the certificate does not contain a valid Rift extension
      RiftCertDecoder.extractEd25519PublicKey(peerCert.pem);
      
      // In a real flow, we would register this socket under the derived Device ID
      // For now, we just attach the stream listener.
      _activeSockets.add(socket);
      
      socket.cast<List<int>>().transform(RiftFrameTransformer()).listen(
        (String jsonString) {
          _messageController.add(jsonString);
        },
        onError: (e) {
          socket.destroy();
          _activeSockets.remove(socket);
        },
        onDone: () {
          _activeSockets.remove(socket);
        },
      );
    } on CertificateDecoderException catch (_) {
      // Fail-closed: malicious or invalid certificate
      socket.destroy();
    }
  }

  @override
  Future<void> sendMessage(String deviceId, dynamic message) async {
    // Temporary naive implementation for week 4 (broadcasting to all sockets)
    // A proper implementation would route by deviceId
    var frame = RiftFrameCodec.encode(jsonEncode(message));
    for (var socket in _activeSockets) {
      socket.add(frame);
    }
  }
}
