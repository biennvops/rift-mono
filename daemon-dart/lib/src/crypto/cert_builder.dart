import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:asn1lib/asn1lib.dart';
import 'package:basic_utils/basic_utils.dart';

class CertificateBuilderException implements Exception {
  final String message;
  final dynamic cause;
  CertificateBuilderException(this.message, [this.cause]);
  @override
  String toString() =>
      'CertificateBuilderException: $message ${cause != null ? '(Cause: $cause)' : ''}';
}

class RiftCertBuilder {
  // TODO(Bien): Cross-check with ADR-0001. May need to switch to PEN branch
  // (1.3.6.1.4.1.XXXXX) if the protocol OID assignment changes.
  static const String riftCustomOid =
      '2.25.293029629918709742181702189012786017422';

  // Base-128 DER encoding of riftCustomOid (tag 0x06, length 0x14 = 20 bytes).
  static final Uint8List riftCustomOidBytes = Uint8List.fromList([
    0x06,
    0x14,
    0x69,
    0x83,
    0xB8,
    0xF3,
    0xBA,
    0x8C,
    0xBA,
    0xBF,
    0xCA,
    0xD1,
    0xCD,
    0x9A,
    0xAB,
    0xF7,
    0x88,
    0x88,
    0x95,
    0xFB,
    0xE9,
    0x0E,
  ]);

  static const String defaultCn = 'RiftDevice';
  static const String defaultSerial = '1';
  static const int defaultValidityDays = 365;
  static const String signatureAlgorithm = 'SHA-256/ECDSA';

  static Uint8List _encodeLength(int length) {
    if (length < 128) {
      return Uint8List.fromList([length]);
    }
    var bytes = <int>[];
    var temp = length;
    while (temp > 0) {
      bytes.insert(0, temp & 0xFF);
      temp >>= 8;
    }
    var header = 0x80 | bytes.length;
    return Uint8List.fromList([header, ...bytes]);
  }

  /// Generates an ASN.1 sequence of the custom extension
  /// containing an Ed25519 public key.
  static ASN1Sequence createEd25519Extension(Uint8List ed25519PubKey) {
    if (ed25519PubKey.length != 32) {
      throw CertificateBuilderException(
        'Invalid Ed25519 public key length: expected 32 bytes, got ${ed25519PubKey.length}',
      );
    }
    var extension = ASN1Sequence();

    extension.add(ASN1ObjectIdentifier.fromBytes(riftCustomOidBytes));

    // 'critical' is DEFAULT FALSE in X.509; DER requires omitting it entirely.

    // Double OCTET STRING wrapping required by X.509 extnValue encoding.
    var innerOctetString = ASN1OctetString(ed25519PubKey);
    var outerOctetString = ASN1OctetString(innerOctetString.encodedBytes);

    extension.add(outerOctetString);

    return extension;
  }

  /// Builds a self-signed ECDSA certificate with the custom extension.
  static String generateSelfSignedCert(
    AsymmetricKeyPair<PublicKey, PrivateKey> ecdsaKeyPair,
    Uint8List ed25519PubKey, {
    String commonName = defaultCn,
    /// Pass null (default) to generate a random RFC 5280-compliant 64-bit serial.
    String? serialNumber,
    int validityDays = defaultValidityDays,
  }) {
    if (ed25519PubKey.length != 32) {
      throw CertificateBuilderException(
        'Invalid Ed25519 public key length: expected 32 bytes, got ${ed25519PubKey.length}',
      );
    }
    try {
      var privKey = ecdsaKeyPair.privateKey as ECPrivateKey;
      var pubKey = ecdsaKeyPair.publicKey as ECPublicKey;

      // RFC 5280: Serial numbers must be unique to prevent caching issues.
      var actualSerialNumber = serialNumber;
      if (actualSerialNumber == null) {
        var random = Random.secure();
        var bytes = List.generate(8, (_) => random.nextInt(256));
        var hexStr = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        actualSerialNumber = BigInt.parse(hexStr, radix: 16).toString();
      }

      var csr = X509Utils.generateEccCsrPem({'CN': commonName}, privKey, pubKey);
      var baseCertPem = X509Utils.generateSelfSignedCertificate(
        privKey, csr, validityDays, serialNumber: actualSerialNumber,
      );

      var certBytes = CryptoUtils.getBytesFromPEMString(baseCertPem);
      var parser = ASN1Parser(certBytes);
      var certObj = parser.nextObject();

      if (certObj is! ASN1Sequence || certObj.elements.length < 3) {
        throw CertificateBuilderException('Invalid base certificate structure');
      }
      var certSeq = certObj;
      var tbsObj = certSeq.elements[0];
      if (tbsObj is! ASN1Sequence) {
        throw CertificateBuilderException('Invalid TBS certificate structure');
      }
      var tbsSeq = tbsObj;

      // sigAlg is taken verbatim from the base cert (basic_utils, SHA-256/ECDSA).
      // If basic_utils changes the algorithm, verify this field stays consistent.
      var sigAlg = certSeq.elements[1];

      var extSequence = createEd25519Extension(ed25519PubKey);
      var extensionsContainer = ASN1Sequence();
      extensionsContainer.add(extSequence);
      var extBytes = extensionsContainer.encodedBytes;

      // Wrap with [3] EXPLICIT context tag (0xA3) as required by X.509.
      var lengthBytes = _encodeLength(extBytes.length);
      var tagBytes = Uint8List.fromList([0xA3, ...lengthBytes, ...extBytes]);

      var tbsBuilder = BytesBuilder(copy: false);
      for (var e in tbsSeq.elements) {
        tbsBuilder.add(e.encodedBytes);
      }
      tbsBuilder.add(tagBytes);
      var tbsInnerBytes = tbsBuilder.takeBytes();

      var newTbsLengthBytes = _encodeLength(tbsInnerBytes.length);
      var newTbsBytes = Uint8List.fromList([
        0x30, ...newTbsLengthBytes, ...tbsInnerBytes,
      ]);

      var signature = CryptoUtils.ecSign(
        privKey, newTbsBytes, algorithmName: signatureAlgorithm,
      );

      var sigSeq = ASN1Sequence();
      sigSeq.add(ASN1Integer(signature.r));
      sigSeq.add(ASN1Integer(signature.s));

      // BIT STRING requires a leading 0x00 byte (0 unused bits).
      var sigBytes = Uint8List(sigSeq.encodedBytes.length + 1);
      sigBytes[0] = 0;
      sigBytes.setRange(1, sigBytes.length, sigSeq.encodedBytes);

      var bitStringEncoded = Uint8List.fromList([
        0x03, ..._encodeLength(sigBytes.length), ...sigBytes,
      ]);

      var certBuilder = BytesBuilder(copy: false);
      certBuilder.add(newTbsBytes);
      certBuilder.add(sigAlg.encodedBytes);
      certBuilder.add(bitStringEncoded);
      var newCertInner = certBuilder.takeBytes();

      var newCertLength = _encodeLength(newCertInner.length);
      var newCertBytes = Uint8List.fromList([
        0x30, ...newCertLength, ...newCertInner,
      ]);

      var base64Cert = base64Encode(newCertBytes);
      var lines = <String>['-----BEGIN CERTIFICATE-----'];
      for (var i = 0; i < base64Cert.length; i += 64) {
        lines.add(
          base64Cert.substring(i, i + 64 < base64Cert.length ? i + 64 : base64Cert.length),
        );
      }
      lines.add('-----END CERTIFICATE-----');
      return lines.join('\n');
    } catch (e) {
      if (e is CertificateBuilderException) rethrow;
      throw CertificateBuilderException('Failed to generate self-signed certificate', e);
    }
  }
}
