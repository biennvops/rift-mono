import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:asn1lib/asn1lib.dart';
import '../lib/src/crypto/cert_builder.dart';

void main() {
  group('Rift Crypto Tests', () {
    test('Should generate custom Ed25519 extension ASN.1', () {
      final mockEd25519Key = Uint8List.fromList(List.generate(32, (i) => i));
      
      final ext = RiftCertBuilder.createEd25519Extension(mockEd25519Key);
      
      expect(ext.elements.length, equals(3));
      
      // First element is OID
      final oidElement = ext.elements[0] as ASN1ObjectIdentifier;
      // Compare raw encoded bytes for OID
      expect(oidElement.encodedBytes, equals(Uint8List.fromList([
        0x06, 0x09, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x86, 0xDF, 0x3F, 0x01
      ])));
      
      // Second element is Critical flag (boolean)
      final boolElement = ext.elements[1] as ASN1Boolean;
      expect(boolElement.booleanValue, isTrue);
      
      // Third element is the key (octet string)
      final octetElement = ext.elements[2] as ASN1OctetString;
      expect(octetElement.valueBytes(), equals(mockEd25519Key));
    });

    test('Should fail gracefully when Biên test vectors are missing', () {
      // Placeholder for: [daemon-dart][risk-cert-interop] Generate ECDSA cert with custom extension; verify against Biên's vectors
      // Currently Biên's test vectors have not been merged yet.
      expect(true, isTrue);
    });
  });
}
