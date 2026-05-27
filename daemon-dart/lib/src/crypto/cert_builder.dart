import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:asn1lib/asn1lib.dart';
import 'package:basic_utils/basic_utils.dart';

class CertificateBuilderException implements Exception {
  final String message;
  final dynamic cause;
  CertificateBuilderException(this.message, [this.cause]);
  @override
  String toString() => 'CertificateBuilderException: $message ${cause != null ? '(Cause: $cause)' : ''}';
}

class RiftCertBuilder {
  // TODO(Biên): Kiểm tra chéo với ADR-0001. Có thể phải đổi sang OID nhánh PEN (1.3.6.1.4.1.XXXXX) nếu protocol thay đổi.
  // Custom OID for Rift Device ID
  static const String riftCustomOid = '2.25.293029629918709742181702189012786017422';
  
  // Encoded Base-128 bytes of the Custom OID (0x06 is OID tag, 0x14 is length 20 bytes)
  static final Uint8List riftCustomOidBytes = Uint8List.fromList([
    0x06, 0x14, 0x69, 0x83, 0xB8, 0xF3, 0xBA, 0x8C, 0xBA, 0xBF, 
    0xCA, 0xD1, 0xCD, 0x9A, 0xAB, 0xF7, 0x88, 0x88, 0x95, 0xFB, 0xE9, 0x0E
  ]);
  
  // Cấu hình mặc định, tránh hardcode business rules (Tuân thủ Mục 2.3)
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
      throw CertificateBuilderException('Invalid Ed25519 public key length: expected 32 bytes, got ${ed25519PubKey.length}');
    }
    var extension = ASN1Sequence();
    
    // Dùng hằng số mảng byte đã được khai báo ở đầu class
    extension.add(ASN1ObjectIdentifier.fromBytes(riftCustomOidBytes));
    
    // Note: 'critical' is DEFAULT FALSE in X.509, so DER encoding rules require omitting it entirely.
    
    // Octet string containing the Ed25519 key
    extension.add(ASN1OctetString(ed25519PubKey));
    
    return extension;
  }

  /// Builds a self-signed ECDSA certificate with the custom extension.
  static String generateSelfSignedCert(
    AsymmetricKeyPair<PublicKey, PrivateKey> ecdsaKeyPair, 
    Uint8List ed25519PubKey, {
    String commonName = defaultCn,
    String serialNumber = defaultSerial,
    int validityDays = defaultValidityDays,
  }) {
    if (ed25519PubKey.length != 32) {
      throw CertificateBuilderException('Invalid Ed25519 public key length: expected 32 bytes, got ${ed25519PubKey.length}');
    }
    try {
      var privKey = ecdsaKeyPair.privateKey as ECPrivateKey;
      var pubKey = ecdsaKeyPair.publicKey as ECPublicKey;

      // 1. Generate base self-signed certificate using basic_utils
      var csr = X509Utils.generateEccCsrPem({'CN': commonName}, privKey, pubKey);
      var baseCertPem = X509Utils.generateSelfSignedCertificate(privKey, csr, validityDays, serialNumber: serialNumber);
    
    // 2. Decode the base cert to inject the custom extension
    var certBytes = CryptoUtils.getBytesFromPEMString(baseCertPem);
    var parser = ASN1Parser(certBytes);
    var certSeq = parser.nextObject() as ASN1Sequence;
    
    var tbsSeq = certSeq.elements[0] as ASN1Sequence;
    var sigAlg = certSeq.elements[1];
    
    // 3. Build the extensions container
    var extSequence = createEd25519Extension(ed25519PubKey);
    var extensionsContainer = ASN1Sequence();
    extensionsContainer.add(extSequence);
    var extBytes = extensionsContainer.encodedBytes;
    
    // 4. Wrap with Context specific tag [3] Constructed = 0xA3
    var lengthBytes = _encodeLength(extBytes.length);
    var tagBytes = Uint8List.fromList([0xA3, ...lengthBytes, ...extBytes]);
    
    // 5. Create a new TBS Certificate by appending the extensions tag to the inner bytes
    var tbsInnerBytes = <int>[];
    for (var e in tbsSeq.elements) {
      tbsInnerBytes.addAll(e.encodedBytes);
    }
    tbsInnerBytes.addAll(tagBytes); 
    
    var newTbsLengthBytes = _encodeLength(tbsInnerBytes.length);
    var newTbsBytes = Uint8List.fromList([0x30, ...newTbsLengthBytes, ...tbsInnerBytes]);
    
    // 6. Sign the new TBS Certificate bytes
    var signature = CryptoUtils.ecSign(privKey, newTbsBytes, algorithmName: signatureAlgorithm);
    
    var sigSeq = ASN1Sequence();
    sigSeq.add(ASN1Integer(signature.r));
    sigSeq.add(ASN1Integer(signature.s));
    
    // X.509 BIT STRING requires a leading zero byte indicating 0 unused bits
    var sigBytes = Uint8List(sigSeq.encodedBytes.length + 1);
    sigBytes[0] = 0;
    sigBytes.setRange(1, sigBytes.length, sigSeq.encodedBytes);
    
    var bitStringHeader = <int>[0x03];
    var bitStringLength = _encodeLength(sigBytes.length);
    var bitStringEncoded = Uint8List.fromList([...bitStringHeader, ...bitStringLength, ...sigBytes]);
    
    // 7. Assemble the final Certificate Sequence
    var newCertInner = <int>[];
    newCertInner.addAll(newTbsBytes);
    newCertInner.addAll(sigAlg.encodedBytes);
    newCertInner.addAll(bitStringEncoded);
    
    var newCertLength = _encodeLength(newCertInner.length);
    var newCertBytes = Uint8List.fromList([0x30, ...newCertLength, ...newCertInner]);
    
    // 8. Base64 encode and wrap in PEM headers
    var base64Cert = base64Encode(newCertBytes);
    var lines = <String>['-----BEGIN CERTIFICATE-----'];
    for (var i = 0; i < base64Cert.length; i += 64) {
      lines.add(base64Cert.substring(i, i + 64 < base64Cert.length ? i + 64 : base64Cert.length));
    }
    lines.add('-----END CERTIFICATE-----');
    
    return lines.join('\n');
    } catch (e, stackTrace) {
      // Tuân thủ Mục 4 & 7: Minh bạch lỗi, ghi log nguyên nhân và bắt Exception
      developer.log(
        'Failed to generate certificate. Lỗi parse hoặc build ASN.1',
        name: 'RiftCertBuilder',
        error: e,
        stackTrace: stackTrace,
      );
      throw CertificateBuilderException('Failed to generate self-signed certificate', e);
    }
  }
}
