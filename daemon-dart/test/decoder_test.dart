
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';

Uint8List _encodeLength(int length) {
  if (length < 128) return Uint8List.fromList([length]);
  var bytes = <int>[];
  var temp = length;
  while (temp > 0) {
    bytes.insert(0, temp & 0xFF);
    temp >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

String _createTestCert(List<ASN1Sequence> extensions) {
  var keyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
  var privKey = keyPair.privateKey as ECPrivateKey;
  var pubKey = keyPair.publicKey as ECPublicKey;

  var csr = X509Utils.generateEccCsrPem({'CN': 'Test'}, privKey, pubKey);
  var baseCertPem = X509Utils.generateSelfSignedCertificate(privKey, csr, 365, serialNumber: '1');

  var certBytes = CryptoUtils.getBytesFromPEMString(baseCertPem);
  var parser = ASN1Parser(certBytes);
  var certSeq = parser.nextObject() as ASN1Sequence;
  var tbsSeq = certSeq.elements[0] as ASN1Sequence;
  var sigAlg = certSeq.elements[1];

  var extensionsContainer = ASN1Sequence();
  for (var ext in extensions) {
    extensionsContainer.add(ext);
  }
  var extBytes = extensionsContainer.encodedBytes;

  var tagBytes = Uint8List.fromList([0xA3, ..._encodeLength(extBytes.length), ...extBytes]);

  var tbsBuilder = BytesBuilder(copy: false);
  for (var e in tbsSeq.elements) {
    tbsBuilder.add(e.encodedBytes);
  }
  tbsBuilder.add(tagBytes);
  var tbsInnerBytes = tbsBuilder.takeBytes();
  var newTbsBytes = Uint8List.fromList([0x30, ..._encodeLength(tbsInnerBytes.length), ...tbsInnerBytes]);

  var sigBytes = Uint8List.fromList([0x00, 0x01, 0x02]); // Fake signature is enough for parser
  var bitStringEncoded = Uint8List.fromList([0x03, ..._encodeLength(sigBytes.length), ...sigBytes]);

  var certBuilder = BytesBuilder(copy: false);
  certBuilder.add(newTbsBytes);
  certBuilder.add(sigAlg.encodedBytes);
  certBuilder.add(bitStringEncoded);
  var newCertInner = certBuilder.takeBytes();
  var newCertBytes = Uint8List.fromList([0x30, ..._encodeLength(newCertInner.length), ...newCertInner]);

  var base64Cert = base64Encode(newCertBytes);
  var lines = <String>['-----BEGIN CERTIFICATE-----'];
  for (var i = 0; i < base64Cert.length; i += 64) {
    lines.add(base64Cert.substring(i, i + 64 < base64Cert.length ? i + 64 : base64Cert.length));
  }
  lines.add('-----END CERTIFICATE-----');
  return lines.join('\n');
}

void main() {
  group('RiftCertDecoder Security Tests (Fail-Closed)', () {
    final mockEd25519Key = Uint8List.fromList(List.generate(32, (i) => i));

    test('Class 0: Should successfully extract valid 32-byte Ed25519 key', () {
      var keyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      String certPem = RiftCertBuilder.generateSelfSignedCert(keyPair, mockEd25519Key);
      var extractedKey = RiftCertDecoder.extractEd25519PublicKey(certPem);
      expect(extractedKey, equals(mockEd25519Key));
    });

    test('Class 1: Should throw on missing extension', () {
      var pem = _createTestCert([]);
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('not found'))),
      );
    });

    test('Class 2: Should throw on duplicated extension', () {
      var ext = RiftCertBuilder.createEd25519Extension(mockEd25519Key);
      var pem = _createTestCert([ext, ext]);
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('duplicated'))),
      );
    });

    test('Class 3: Should throw if extension is marked critical', () {
      var ext = ASN1Sequence();
      ext.add(ASN1ObjectIdentifier.fromBytes(RiftCertBuilder.riftCustomOidBytes));
      ext.add(ASN1Boolean(true)); // CRITICAL
      ext.add(ASN1OctetString(ASN1OctetString(mockEd25519Key).encodedBytes));
      var pem = _createTestCert([ext]);
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('non-critical'))),
      );
    });

    test('Class 4: Should throw if unknown extension is marked Critical', () {
      var unknownOid = ASN1ObjectIdentifier.fromBytes(Uint8List.fromList([0x06, 0x03, 0x55, 0x04, 0x03])); // Random OID
      var ext = ASN1Sequence();
      ext.add(unknownOid);
      ext.add(ASN1Boolean(true)); // CRITICAL
      ext.add(ASN1OctetString(Uint8List.fromList([0x01])));
      
      var validExt = RiftCertBuilder.createEd25519Extension(mockEd25519Key);
      var pem = _createTestCert([ext, validExt]);
      
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('Unsupported critical extension'))),
      );
    });

    test('Class 5: Should throw if inner key is < 32 bytes', () {
      var shortKey = Uint8List.fromList(List.generate(31, (i) => i));
      var ext = ASN1Sequence();
      ext.add(ASN1ObjectIdentifier.fromBytes(RiftCertBuilder.riftCustomOidBytes));
      ext.add(ASN1OctetString(ASN1OctetString(shortKey).encodedBytes));
      var pem = _createTestCert([ext]);
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('length: 31'))),
      );
    });

    test('Class 6: Should throw if inner key is > 32 bytes', () {
      var longKey = Uint8List.fromList(List.generate(33, (i) => i));
      var ext = ASN1Sequence();
      ext.add(ASN1ObjectIdentifier.fromBytes(RiftCertBuilder.riftCustomOidBytes));
      ext.add(ASN1OctetString(ASN1OctetString(longKey).encodedBytes));
      var pem = _createTestCert([ext]);
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('length: 33'))),
      );
    });

    test('Class 7: Should throw if wrong DER tag (not OCTET STRING)', () {
      var ext = ASN1Sequence();
      ext.add(ASN1ObjectIdentifier.fromBytes(RiftCertBuilder.riftCustomOidBytes));
      ext.add(ASN1OctetString(ASN1BitString(mockEd25519Key).encodedBytes)); // BIT STRING instead of OCTET STRING
      var pem = _createTestCert([ext]);
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('is not an OCTET STRING'))),
      );
    });

    test('Class 8: Should throw on malformed PEM (Truncated DER)', () {
      String badPem = '-----BEGIN CERTIFICATE-----\nBADBASE64DATA\n-----END CERTIFICATE-----';
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(badPem),
        throwsA(isA<CertificateDecoderException>()),
      );
    });

    test('Class 9: Should throw if OID encoding is altered (Fragile OID match test)', () {
      var ext = RiftCertBuilder.createEd25519Extension(mockEd25519Key);
      var bytes = ext.encodedBytes;
      // Flip a bit in the OID data to simulate an altered but structurally valid ASN.1 OID
      bytes[10] ^= 0x01; 
      var alteredExt = ASN1Sequence.fromBytes(bytes);
      var pem = _createTestCert([alteredExt]);
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(pem),
        throwsA(isA<CertificateDecoderException>().having((e) => e.message, 'msg', contains('not found'))),
      );
    });
  });
}
