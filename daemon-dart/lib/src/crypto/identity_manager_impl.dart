

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
  SimpleKeyPair? _cachedKeyPair;

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
      
      // Save it durably using Atomic Write to prevent corruption on crash
      await keyFile.parent.create(recursive: true);
      var tempFile = File('${keyFile.path}.tmp');
      await tempFile.writeAsBytes(_privateKey, flush: true);
      await tempFile.rename(keyFile.path);
      // TODO(Security): Integrate Android Keystore via Flutter channels to avoid plaintext Ed25519 seed storage. (Target: M3 - Tuần 5)
      
      await _derivePublicKey();
    }
  }

  Future<void> _derivePublicKey() async {
    var algorithm = Ed25519();
    _cachedKeyPair = await algorithm.newKeyPairFromSeed(_privateKey);
    var pubKeyObj = await _cachedKeyPair!.extractPublicKey();
    _publicKey = Uint8List.fromList(pubKeyObj.bytes);

    // Calculate Fingerprint: SHA-256(Ed25519 pubkey)
    var sha256 = Sha256();
    var hash = await sha256.hash(_publicKey);
    _fingerprintBytes = Uint8List.fromList(hash.bytes);

    // Calculate Device ID: rift- + first 32 chars of lowercase Base32(fingerprint)
    var base32Str = _encodeBase32(_fingerprintBytes).toLowerCase();
    _deviceId = 'rift-${base32Str.substring(0, 32)}';
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

  @override
  Future<Uint8List> signIdentityProof(Uint8List channelBinding, Uint8List certHash) async {
    if (_cachedKeyPair == null) throw StateError('IdentityManager not initialized');
    if (channelBinding.length != 32) {
      throw ArgumentError('channelBinding must be exactly 32 bytes');
    }
    if (certHash.length != 32) {
      throw ArgumentError('certHash must be exactly 32 bytes');
    }

    // Protocol Section 5.3.1: RiftPoP-v2: + channelBinding + publicKey + certHash
    final prefix = Uint8List.fromList('RiftPoP-v2:'.codeUnits);
    final builder = BytesBuilder(copy: false);
    builder.add(prefix);
    builder.add(channelBinding);
    builder.add(_publicKey);
    builder.add(certHash);

    final payload = builder.takeBytes();
    final algorithm = Ed25519();
    final signature = await algorithm.sign(payload, keyPair: _cachedKeyPair!);
    return Uint8List.fromList(signature.bytes);
  }

  @override
  Future<void> dispose() async {
    for (var i = 0; i < _privateKey.length; i++) {
      _privateKey[i] = 0;
    }
    _cachedKeyPair = null;
  }
}
