import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:asn1lib/asn1lib.dart';
import 'cert_builder.dart';

class CertificateDecoderException implements Exception {
  final String message;
  final dynamic cause;
  CertificateDecoderException(this.message, [this.cause]);
  @override
  String toString() =>
      'CertificateDecoderException: $message ${cause != null ? '(Cause: $cause)' : ''}';
}

class RiftCertDecoder {
  /// Extracts the 32-byte Ed25519 public key from the custom X.509 extension.
  /// Enforces Fail-Closed principle: throws [CertificateDecoderException] if malformed or missing.
  static Uint8List extractEd25519PublicKey(String pemCert) {
    try {
      // 1. Decode PEM to raw DER bytes
      var lines = pemCert.split('\n');
      var base64Str = lines
          .where((l) => l.trim().isNotEmpty && !l.startsWith('-----'))
          .join('');
      var certBytes = base64Decode(base64Str);

      var asn1Parser = ASN1Parser(certBytes);
      var seq = asn1Parser.nextObject() as ASN1Sequence;

      var tbsCertificate = seq.elements[0] as ASN1Sequence;

      // 2. Locate the extensions block [3] in TBSCertificate
      ASN1Sequence? extensionsSeq;
      for (var element in tbsCertificate.elements) {
        if (element.tag == 0xA3) {
          // Context-specific tag [3] for extensions
          var extDataParser = ASN1Parser(element.valueBytes());
          extensionsSeq = extDataParser.nextObject() as ASN1Sequence;
          break;
        }
      }

      if (extensionsSeq == null) {
        throw CertificateDecoderException(
          'No extensions block [3] found in certificate',
        );
      }

      // 3. Find our custom extension by matching OID bytes
      Uint8List? extractedKeyBytes;
      for (var ext in extensionsSeq.elements) {
        if (ext is ASN1Sequence && ext.elements.isNotEmpty) {
          var oidElement = ext.elements[0];

          if (oidElement is ASN1ObjectIdentifier) {
            // Compare raw byte array since asn1lib cannot parse massive UUID OID
            bool isCustomOid = _compareBytes(
              oidElement.encodedBytes,
              RiftCertBuilder.riftCustomOidBytes,
            );

            if (isCustomOid) {
              // Standard X.509 extension structure: SEQUENCE { extnID OID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
              // Since critical is false and omitted by RiftCertBuilder, extnValue is usually the second element (index 1).
              ASN1OctetString? octetStringElement;

              if (ext.elements.length == 2 &&
                  ext.elements[1] is ASN1OctetString) {
                octetStringElement = ext.elements[1] as ASN1OctetString;
              } else if (ext.elements.length == 3 &&
                  ext.elements[2] is ASN1OctetString) {
                // Just in case another implementation includes the critical boolean flag
                octetStringElement = ext.elements[2] as ASN1OctetString;
              }

              if (octetStringElement != null) {
                // The value inside the OCTET STRING might itself be DER encoded (e.g. another OCTET STRING),
                // but RiftCertBuilder encodes it directly as the primitive OCTET STRING.
                // We extract the pure payload bytes.
                extractedKeyBytes = octetStringElement.valueBytes();
                break;
              }
            }
          }
        }
      }

      if (extractedKeyBytes == null) {
        throw CertificateDecoderException(
          'Custom Rift Extension (OID ${RiftCertBuilder.riftCustomOid}) not found',
        );
      }

      // 4. Validate exact 32-byte length (Fail-Closed)
      if (extractedKeyBytes.length != 32) {
        throw CertificateDecoderException(
          'Invalid extracted Ed25519 key length: expected 32 bytes, got ${extractedKeyBytes.length}',
        );
      }

      return extractedKeyBytes;
    } catch (e, stackTrace) {
      developer.log(
        'Failed to decode certificate or extract Ed25519 key',
        name: 'RiftCertDecoder',
        error: e,
        stackTrace: stackTrace,
      );
      if (e is CertificateDecoderException) {
        rethrow;
      }
      throw CertificateDecoderException(
        'Malformed certificate or ASN.1 parsing error',
        e,
      );
    }
  }

  /// Utility to compare two Uint8List securely
  static bool _compareBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
