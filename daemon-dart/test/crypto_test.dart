import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';

void main() {
  group('Rift Crypto Tests', () {
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
  });
}
