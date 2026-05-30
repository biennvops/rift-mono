// test/decoder_test.dart

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';

void main() {
  group('RiftCertDecoder Tests', () {
    test('Should successfully extract valid 32-byte Ed25519 key', () {
      var keyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      var mockEd25519Key = Uint8List.fromList(List.generate(32, (i) => i));
      
      String certPem = RiftCertBuilder.generateSelfSignedCert(keyPair, mockEd25519Key);
      
      var extractedKey = RiftCertDecoder.extractEd25519PublicKey(certPem);
      expect(extractedKey, equals(mockEd25519Key));
    });

    test('Should throw CertificateDecoderException on malformed PEM', () {
      String badPem = '-----BEGIN CERTIFICATE-----\nBADBASE64DATA\n-----END CERTIFICATE-----';
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(badPem),
        throwsA(isA<CertificateDecoderException>()),
      );
    });

    test('Should throw CertificateDecoderException if Rift Custom OID is missing', () {
      var keyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      var privKey = keyPair.privateKey as ECPrivateKey;
      var pubKey = keyPair.publicKey as ECPublicKey;

      var csr = X509Utils.generateEccCsrPem({'CN': 'NormalCert'}, privKey, pubKey);
      var certPem = X509Utils.generateSelfSignedCertificate(privKey, csr, 365, serialNumber: '1');
      
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(certPem),
        throwsA(
          isA<CertificateDecoderException>().having(
            (e) => e.message,
            'message',
            contains('No extensions found'),
          ),
        ),
      );
    });
  });
}
