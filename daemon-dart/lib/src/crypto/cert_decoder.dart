
import 'dart:typed_data';
import 'package:asn1lib/asn1lib.dart';
import 'package:basic_utils/basic_utils.dart';
import 'cert_builder.dart';

class CertificateDecoderException implements Exception {
  final String message;
  CertificateDecoderException(this.message);
  @override
  String toString() => 'CertificateDecoderException: $message';
}

/// A highly secure, fail-closed X.509 ASN.1 Parser specifically built for Rift.
class RiftCertDecoder {
  static String _hexPreview(Uint8List bytes, {int maxBytes = 12}) {
    final end = bytes.length < maxBytes ? bytes.length : maxBytes;
    final parts = <String>[];
    for (var i = 0; i < end; i++) {
      parts.add(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    if (bytes.length > end) {
      parts.add('...');
    }
    return parts.join(' ');
  }

  static Uint8List _unwrapEd25519ExtensionValue(Uint8List bytes) {
    if (bytes.length == 32) {
      return Uint8List.fromList(bytes);
    }

    // Direct OCTET STRING wrapper: 04 <len> <payload>
    if (bytes.length >= 2 && bytes[0] == 0x04 && bytes[1] == bytes.length - 2) {
      return Uint8List.sublistView(bytes, 2);
    }

    // Double-wrapped OCTET STRING: 04 22 04 20 <32 bytes>
    if (bytes.length == 36 &&
        bytes[0] == 0x04 &&
        bytes[1] == 0x22 &&
        bytes[2] == 0x04 &&
        bytes[3] == 0x20) {
      return Uint8List.sublistView(bytes, 4);
    }

    try {
      final innerParser = ASN1Parser(bytes);
      final innerObj = innerParser.nextObject();
      if (innerObj.encodedBytes.length != bytes.length || innerObj.tag != 0x04) {
        throw CertificateDecoderException('Inner value is not an OCTET STRING');
      }
      final innerValue = innerObj.valueBytes();
      return _unwrapEd25519ExtensionValue(Uint8List.fromList(innerValue));
    } on CertificateDecoderException {
      rethrow;
    } catch (e) {
      throw CertificateDecoderException('Malformed inner OCTET STRING: $e');
    }
  }

  /// Extracts the Ed25519 public key from a Rift mTLS certificate.
  /// Throws [CertificateDecoderException] if the certificate is malformed,
  /// missing the custom extension, or if the key length is invalid (Fail-Closed).
  static Uint8List extractEd25519PublicKey(String pem) {
    try {
      var certBytes = CryptoUtils.getBytesFromPEMString(pem);
      return extractEd25519PublicKeyFromDer(certBytes);
    } catch (e) {
      if (e is CertificateDecoderException) rethrow;
      throw CertificateDecoderException('Failed to parse PEM certificate: $e');
    }
  }

  /// Extracts the Ed25519 public key from a Rift mTLS certificate in DER format.
  static Uint8List extractEd25519PublicKeyFromDer(Uint8List der) {
    try {
      var parser = ASN1Parser(der);
      var certObj = parser.nextObject();

      if (certObj is! ASN1Sequence || certObj.elements.isEmpty) {
        throw CertificateDecoderException('Invalid base certificate structure');
      }

      var tbsObj = certObj.elements[0];
      if (tbsObj is! ASN1Sequence) {
        throw CertificateDecoderException('Invalid TBS certificate structure');
      }

      // X.509 TBSCertificate has [3] EXPLICIT Extensions at the end
      ASN1Object? extensionsTag;
      for (var e in tbsObj.elements) {
        if (e.tag == 0xA3) {
          extensionsTag = e;
          break;
        }
      }

      if (extensionsTag == null) {
        throw CertificateDecoderException('No extensions found in certificate');
      }

      var extParser = ASN1Parser(extensionsTag.valueBytes());
      var extSequence = extParser.nextObject();
      if (extSequence is! ASN1Sequence) {
        throw CertificateDecoderException('Invalid extensions structure');
      }

      Uint8List? extractedKey;

      // Iterate through the extensions
      for (var ext in extSequence.elements) {
        if (ext is! ASN1Sequence || ext.elements.isEmpty) {
          continue;
        }

        var oidObj = ext.elements[0];
        if (oidObj.tag != 0x06) continue; // Not an OID

        // Check if this is the Rift Custom OID
        bool isRiftOid = true;
        var oidBytes = oidObj.encodedBytes;
        if (oidBytes.length != RiftCertBuilder.riftCustomOidBytes.length) {
          isRiftOid = false;
        } else {
          for (int i = 0; i < oidBytes.length; i++) {
            if (oidBytes[i] != RiftCertBuilder.riftCustomOidBytes[i]) {
              isRiftOid = false;
              break;
            }
          }
        }

        if (isRiftOid) {
          if (extractedKey != null) {
            throw CertificateDecoderException('Rift Custom OID extension is duplicated');
          }

          var valueIndex = 1;
          if (ext.elements.length <= valueIndex) {
            throw CertificateDecoderException('Malformed Rift extension: missing extnValue');
          }

          if (ext.elements[valueIndex].tag == 0x01) {
            var criticalBytes = ext.elements[valueIndex].valueBytes();
            if (criticalBytes.isNotEmpty && criticalBytes[0] != 0x00) {
              throw CertificateDecoderException('Rift Custom OID extension must be non-critical');
            }
            valueIndex++;
          }

          if (ext.elements.length != valueIndex + 1) {
            throw CertificateDecoderException('Malformed Rift extension structure');
          }

          var octetStringObj = ext.elements[valueIndex];
          if (octetStringObj.tag != 0x04) {
            throw CertificateDecoderException('Extension value is not an OCTET STRING');
          }

          final innerBytes = Uint8List.fromList(octetStringObj.valueBytes());
          final pubKeyBytes = _unwrapEd25519ExtensionValue(innerBytes);
          
          if (pubKeyBytes.length != 32) {
            throw CertificateDecoderException(
              'Invalid Ed25519 public key length: ${pubKeyBytes.length} bytes (expected 32); '
              'preview=${_hexPreview(pubKeyBytes)}',
            );
          }
          
          extractedKey = Uint8List.fromList(pubKeyBytes);
        } else {
          // Unknown extension. X.509 requires rejecting the certificate if an unsupported extension is marked critical.
          if (ext.elements.length > 1 && ext.elements[1].tag == 0x01) {
            var criticalBytes = ext.elements[1].valueBytes();
            if (criticalBytes.isNotEmpty && criticalBytes[0] != 0x00) {
              throw CertificateDecoderException('Unsupported critical extension encountered');
            }
          }
        }
      }

      if (extractedKey != null) {
        return extractedKey;
      }

      throw CertificateDecoderException('Rift Custom OID extension not found in certificate');
    } on FormatException catch (e) {
      throw CertificateDecoderException('Format error while parsing certificate: $e');
    } on RangeError catch (e) {
      throw CertificateDecoderException('Range error while parsing certificate (likely malformed ASN.1): $e');
    } on ArgumentError catch (e) {
      throw CertificateDecoderException('Invalid argument while parsing certificate: $e');
    }
  }
}
