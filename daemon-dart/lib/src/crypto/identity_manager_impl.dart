// lib/src/crypto/identity_manager_impl.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import '../interfaces/identity_manager.dart';

class IdentityManagerImpl implements IdentityManager {
  final String storagePath;
  late Uint8List _privateKey;
  late Uint8List _publicKey;
  late String _deviceId;
  late Uint8List _fingerprintBytes;

  IdentityManagerImpl(this.storagePath);

  @override
  Future<void> initialize() async {
    var keyFile = File(p.join(storagePath, 'identity.key'));
    if (await keyFile.exists()) {
      _privateKey = await keyFile.readAsBytes();
      if (_privateKey.length != 32) {
        throw Exception('Corrupted identity key file: expected 32 bytes.');
      }
      await _derivePublicKey();
    } else {
      // Generate new Ed25519 seed (private key)
      var random = Random.secure();
      _privateKey = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
      
      // Save it durably
      await keyFile.parent.create(recursive: true);
      await keyFile.writeAsBytes(_privateKey, flush: true);
      
      await _derivePublicKey();
    }
  }

  Future<void> _derivePublicKey() async {
    var algorithm = Ed25519();
    var keyPair = await algorithm.newKeyPairFromSeed(_privateKey);
    var pubKeyObj = await keyPair.extractPublicKey();
    _publicKey = Uint8List.fromList(pubKeyObj.bytes);

    // Calculate Fingerprint: SHA-256(Ed25519 pubkey)
    var sha256 = Sha256();
    var hash = await sha256.hash(_publicKey);
    _fingerprintBytes = Uint8List.fromList(hash.bytes);

    // Calculate Device ID: rift- + first 32 chars of lowercase Base32(fingerprint)
    var base32Str = _encodeBase32(_fingerprintBytes).toLowerCase();
    _deviceId = 'rift-' + base32Str.substring(0, 32);
  }

  @override
  Uint8List getEd25519PublicKey() => _publicKey;

  @override
  Uint8List getDeviceFingerprint() => _fingerprintBytes;

  @override
  String get deviceId => _deviceId;

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
