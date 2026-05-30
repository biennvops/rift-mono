import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';

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
      
      // Second element is the outer OCTET STRING containing the inner OCTET STRING
      final outerOctetElement = ext.elements[1] as ASN1OctetString;
      final innerParser = ASN1Parser(outerOctetElement.valueBytes());
      final innerOctetElement = innerParser.nextObject() as ASN1OctetString;
      expect(innerOctetElement.valueBytes(), equals(mockEd25519Key));
    });

  });
}
