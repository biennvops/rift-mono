import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';
import 'package:pointycastle/export.dart';

void main() {
  group('Rift Crypto Tests', () {
    // (Tuần 2) - Task: [daemon-dart][risk-cert-interop] Generate ECDSA cert with custom extension
    // Ý nghĩa: Đảm bảo thuật toán nhào nặn byte tạo ra đúng cấu trúc Extension X.509
    test('Should generate custom Ed25519 extension ASN.1', () {
      final mockEd25519Key = Uint8List.fromList(List.generate(32, (i) => i));
      
      final ext = RiftCertBuilder.createEd25519Extension(mockEd25519Key);
      
      expect(ext.elements.length, equals(2)); // Omitted critical flag (default false)
      
      // First element is OID
      final oidElement = ext.elements[0] as ASN1ObjectIdentifier;
      // Compare raw encoded bytes for OID
      expect(oidElement.encodedBytes, equals(Uint8List.fromList([
        0x06, 0x14, 0x69, 0x83, 0xB8, 0xF3, 0xBA, 0x8C, 0xBA, 0xBF, 
        0xCA, 0xD1, 0xCD, 0x9A, 0xAB, 0xF7, 0x88, 0x88, 0x95, 0xFB, 0xE9, 0x0E
      ])));
      
      // Second element is the key (octet string)
      final octetElement = ext.elements[1] as ASN1OctetString;
      expect(octetElement.valueBytes(), equals(mockEd25519Key));
    });

    // (Tuần 3) - Task: [daemon-dart][risk-asn1-parser] Custom X.509 ASN.1 parser v1
    // Ý nghĩa: Kiểm tra luồng Parser đọc ngược lại chứng chỉ do chính hệ thống tạo ra (End-to-End)
    test('Should decode Ed25519 key from self-signed certificate (End-to-End)', () {
      // 1. Generate an ECDSA keypair
      final keyParams = ECDomainParameters('prime256v1');
      final secureRandom = SecureRandom('Fortuna')..seed(KeyParameter(Uint8List(32)));
      final keyGenerator = ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(keyParams), secureRandom));
      final ecdsaKeyPair = keyGenerator.generateKeyPair();
      
      // 2. Mock 32-byte Ed25519 key
      final mockEd25519Key = Uint8List.fromList(List.generate(32, (i) => i));

      // 3. Build Cert
      final pemCert = RiftCertBuilder.generateSelfSignedCert(ecdsaKeyPair, mockEd25519Key);

      // 4. Decode Cert
      final extractedKey = RiftCertDecoder.extractEd25519PublicKey(pemCert);

      // 5. Verify byte equality
      expect(extractedKey, equals(mockEd25519Key));
    });

    // (Tuần 3) - Nguyên tắc Fail-Closed (Bảo mật cốt lõi)
    // Ý nghĩa: Đảm bảo Parser ném Exception ngay lập tức khi chứng chỉ hỏng, không nín lặng bỏ qua.
    test('Decoder should fail closed on invalid PEM (Fail-Closed)', () {
      const invalidPem = '-----BEGIN CERTIFICATE-----\nINVALID\n-----END CERTIFICATE-----';
      
      expect(
        () => RiftCertDecoder.extractEd25519PublicKey(invalidPem),
        throwsA(isA<CertificateDecoderException>()),
      );
    });
  });
}
