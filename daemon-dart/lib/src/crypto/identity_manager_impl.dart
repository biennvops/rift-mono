import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:basic_utils/basic_utils.dart';
import '../core/rift_exceptions.dart';
import '../interfaces/identity_manager.dart';
import 'cert_builder.dart';
import 'base32_utils.dart';
import 'pop_manager.dart';

class IdentityManagerImpl implements IdentityManager {
  final String storagePath;
  Uint8List? _privateKey;
  Uint8List? _publicKey;
  String _deviceId = '';
  Uint8List? _fingerprintBytes;
  SimpleKeyPair? _cachedKeyPair;

  String _tlsCertificatePem = '';
  String _tlsPrivateKeyPem = '';
  Uint8List? _tlsCertificateDer;

  IdentityManagerImpl(this.storagePath);

  @override
  Future<void> initialize() async {
    var keyFile = File(p.join(storagePath, 'identity.key'));
    if (await keyFile.exists()) {
      final keyBytes = await keyFile.readAsBytes();
      if (keyBytes.length != 32) {
        throw Exception('Corrupted identity key file: expected 32 bytes.');
      }
      _privateKey = keyBytes;
      await _derivePublicKey();
    } else {
      var random = Random.secure();
      _privateKey = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
      
      // Atomic write: prevents a corrupted key file on crash mid-write.
      await keyFile.parent.create(recursive: true);
      var tempFile = File('${keyFile.path}.tmp');
      await tempFile.writeAsBytes(_privateKey!, flush: true);
      await tempFile.rename(keyFile.path);
      // TODO(Security): Integrate Android Keystore via Flutter channels to avoid
      // plaintext Ed25519 seed storage. (Target: M3 - Week 5)

      await _derivePublicKey();
    }

    // Ephemeral TLS cert: trust root is Ed25519, so TLS cert can be regenerated each session.
    final ecdsaKeyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    _tlsPrivateKeyPem = CryptoUtils.encodeEcPrivateKeyToPem(ecdsaKeyPair.privateKey as ECPrivateKey);
    _tlsCertificatePem = RiftCertBuilder.generateSelfSignedCert(
      ecdsaKeyPair,
      _publicKey!,
      commonName: _deviceId,
    );
    _tlsCertificateDer = _pemToDer(_tlsCertificatePem);
  }

  Future<void> _derivePublicKey() async {
    var algorithm = Ed25519();
    _cachedKeyPair = await algorithm.newKeyPairFromSeed(_privateKey!);
    var pubKeyObj = await _cachedKeyPair!.extractPublicKey();
    _publicKey = Uint8List.fromList(pubKeyObj.bytes);

    var sha256 = Sha256();
    var hash = await sha256.hash(_publicKey!);
    _fingerprintBytes = Uint8List.fromList(hash.bytes);

    // Device ID: 'rift-' + first 32 chars of lowercase Base32(SHA-256(pubkey))
    final base32Str = Base32Utils.encode(_fingerprintBytes!).toLowerCase();
    _deviceId = 'rift-${base32Str.substring(0, 32)}';
  }

  @override
  Uint8List getEd25519PublicKey() => Uint8List.fromList(_publicKey!);

  @override
  Uint8List getDeviceFingerprint() => Uint8List.fromList(_fingerprintBytes!);

  @override
  String get deviceId => _deviceId;

  @override
  String get tlsCertificatePem => _tlsCertificatePem;

  @override
  Uint8List get tlsCertificateDer {
    if (_tlsCertificateDer == null) {
      throw const RiftIdentityNotInitializedException('IdentityManager not initialized');
    }
    return Uint8List.fromList(_tlsCertificateDer!); // Defensive copy to prevent mutation
  }

  @override
  String get tlsPrivateKeyPem => _tlsPrivateKeyPem;

  @override
  Future<String> generateIdentityProof(Uint8List channelBinding, Uint8List localCertDer) async {
    if (_cachedKeyPair == null || _privateKey == null || _publicKey == null) {
      throw const RiftIdentityNotInitializedException('IdentityManager not initialized');
    }
    return await PoPManager.generateIdentityProof(
        channelBinding, _publicKey!, localCertDer, _privateKey!);
  }

  @override
  Future<void> dispose() async {
    if (_privateKey != null) {
      for (var i = 0; i < _privateKey!.length; i++) {
        _privateKey![i] = 0;
      }
      _privateKey = null;
    }
    if (_publicKey != null) {
      for (var i = 0; i < _publicKey!.length; i++) {
        _publicKey![i] = 0;
      }
      _publicKey = null;
    }
    if (_fingerprintBytes != null) {
      for (var i = 0; i < _fingerprintBytes!.length; i++) {
        _fingerprintBytes![i] = 0;
      }
      _fingerprintBytes = null;
    }
    // Zeroize cert DER so it doesn't survive in a heap dump after shutdown.
    if (_tlsCertificateDer != null) {
      for (var i = 0; i < _tlsCertificateDer!.length; i++) {
        _tlsCertificateDer![i] = 0;
      }
      _tlsCertificateDer = null;
    }
    _deviceId = '';
    _tlsCertificatePem = '';
    _tlsPrivateKeyPem = '';
    _cachedKeyPair = null;
  }

  /// Decodes a PEM certificate to DER bytes.
  static Uint8List _pemToDer(String pem) {
    final lines = pem.split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    return Uint8List.fromList(base64.decode(lines));
  }
}
