// lib/src/network/transport_impl.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';


import 'package:basic_utils/basic_utils.dart';

import '../interfaces/transport.dart';
import '../interfaces/identity_manager.dart';
import '../crypto/cert_builder.dart';
import '../crypto/cert_decoder.dart';
import '../crypto/identity_manager_impl.dart';
import 'frame_codec.dart';

class TransportImpl implements Transport {
  final IdentityManager _identityManager;
  final int _port;
  
  SecureServerSocket? _serverSocket;
  final Map<String, SecureSocket> _socketMap = {};
  final StreamController<Uint8List> _messageController = StreamController<Uint8List>.broadcast();
  
  late SecurityContext _securityContext;

  TransportImpl(this._identityManager, this._port);

  @override
  Stream<Uint8List> get onMessageReceived => _messageController.stream;

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

  Future<void> _handleNewConnection(SecureSocket socket) async {
    var peerCert = socket.peerCertificate;
    if (peerCert == null) {
      socket.destroy();
      return;
    }

    try {
      // Post-handshake Ed25519 extraction via Fail-Closed parser
      // Will throw if the certificate does not contain a valid Rift extension
      var peerEd25519Key = RiftCertDecoder.extractEd25519PublicKey(peerCert.pem);
      var peerDeviceId = await IdentityManagerImpl.deriveDeviceId(peerEd25519Key);
      
      _socketMap[peerDeviceId] = socket;
      
      socket.cast<List<int>>().transform(RiftFrameTransformer()).listen(
        (String jsonString) {
          _messageController.add(Uint8List.fromList(utf8.encode(jsonString)));
        },
        onError: (e) {
          socket.destroy();
          _socketMap.remove(peerDeviceId);
        },
        onDone: () {
          _socketMap.remove(peerDeviceId);
        },
      );
      
      // TODO: Notify session manager to send session.hello
    } on CertificateDecoderException catch (_) {
      // Fail-closed: malicious or invalid certificate
      socket.destroy();
    }
  }

  @override
  Future<void> sendMessage(String deviceId, Uint8List message) async {
    var socket = _socketMap[deviceId];
    if (socket != null) {
      var frame = RiftFrameCodec.encode(utf8.decode(message));
      socket.add(frame);
    }
  }
}
