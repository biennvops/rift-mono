import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:asn1lib/asn1lib.dart';

class RiftCertBuilder {
  // Placeholder OID as ADR 0001 is not yet decided
  static const String RIFT_CUSTOM_OID = '1.3.6.1.4.1.99999.1';

  /// Generates a mock ASN.1 representation of a custom extension
  /// containing an Ed25519 public key.
  static ASN1Sequence createEd25519Extension(Uint8List ed25519PubKey) {
    var extension = ASN1Sequence();
    
    // Using raw bytes for OID 1.3.6.1.4.1.99999.1
    // 0x06 is OID tag, 0x09 is length, followed by encoded OID bytes.
    extension.add(ASN1ObjectIdentifier.fromBytes(Uint8List.fromList([
      0x06, 0x09, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x86, 0xDF, 0x3F, 0x01
    ])));
    
    // Critical flag
    extension.add(ASN1Boolean(true)); 
    
    // Octet string containing the Ed25519 key
    extension.add(ASN1OctetString(ed25519PubKey));
    
    return extension;
  }

  /// Builds a self-signed ECDSA certificate with the custom extension.
  static String generateSelfSignedCert(AsymmetricKeyPair<PublicKey, PrivateKey> ecdsaKeyPair, Uint8List ed25519PubKey) {
    // Note: Due to limitations in basic_utils, a full integration of custom 
    // extensions requires manual construction of the TBSCertificate in ASN.1.
    // For Week 2 scope, we demonstrate the generation of the extension payload.
    
    var extSequence = createEd25519Extension(ed25519PubKey);
    
    // In a complete implementation, this extension would be appended to the TBSCertificate
    // and then signed.
    
    return '-----BEGIN MOCK CERT-----\n' + 
           // In actual usage, base64 encode the full cert
           'MOCK DATA' +
           '\n-----END MOCK CERT-----';
  }
}
