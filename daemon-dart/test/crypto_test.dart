import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';

void main() {
  group('Rift Crypto Tests', () {
    // RFC 8032 §7.1 Test Vector 1 key
    final mockEd25519Key = Uint8List.fromList([
      0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7, 0xd5, 0x4b, 0xfe, 0xd3,
      0xc9, 0x64, 0x07, 0x3a, 0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa3, 0xf4, 0xa1,
      0x84, 0x46, 0xb0, 0xb8, 0xd1, 0x83, 0xf8, 0xe3
    ]);

    test('Should generate custom Ed25519 extension ASN.1 conforming to spec', () {
      final ext = RiftCertBuilder.createEd25519Extension(mockEd25519Key);
      
      final expectedDer = Uint8List.fromList([
        0x30, 0x3a, 0x06, 0x14, 0x69, 0x83, 0xb8, 0xf3, 0xba, 0x8c, 0xba, 0xbf,
        0xca, 0xd1, 0xcd, 0x9a, 0xab, 0xf7, 0x88, 0x88, 0x95, 0xfb, 0xe9, 0x0e,
        0x04, 0x22, 0x04, 0x20, 0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
        0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a, 0x0e, 0xe1, 0x72, 0xf3,
        0xda, 0xa3, 0xf4, 0xa1, 0x84, 0x46, 0xb0, 0xb8, 0xd1, 0x83, 0xf8, 0xe3
      ]);
      
      expect(ext.encodedBytes, equals(expectedDer));
    });

    test('Should generate valid self-signed cert containing the extension', () {
      final keyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
      final certPem = RiftCertBuilder.generateSelfSignedCert(keyPair, mockEd25519Key);
      
      // Basic round-trip verification
      final certBytes = CryptoUtils.getBytesFromPEMString(certPem);
      final parser = ASN1Parser(certBytes);
      final certSeq = parser.nextObject() as ASN1Sequence;
      
      final tbsSeq = certSeq.elements[0] as ASN1Sequence;
      // TBS elements: [version, serial, sigAlg, issuer, validity, subject, pki, extensions (context 3)]
      final extensionsObj = tbsSeq.elements.last;
      expect(extensionsObj.tag, equals(0xA3)); // Context specific tag 3
      
      // Verify that the extension is present inside
      final extBytes = extensionsObj.encodedBytes;
      
      final expectedOidSequence = [
        0x06, 0x14, 0x69, 0x83, 0xB8, 0xF3, 0xBA, 0x8C, 0xBA, 0xBF, 
        0xCA, 0xD1, 0xCD, 0x9A, 0xAB, 0xF7, 0x88, 0x88, 0x95, 0xFB, 0xE9, 0x0E
      ];
      
      bool containsOid = false;
      for (int i = 0; i < extBytes.length - expectedOidSequence.length; i++) {
        bool match = true;
        for (int j = 0; j < expectedOidSequence.length; j++) {
          if (extBytes[i + j] != expectedOidSequence[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          containsOid = true;
          break;
        }
      }
      expect(containsOid, isTrue, reason: 'Generated cert should contain the custom OID');
    });
  });
}
