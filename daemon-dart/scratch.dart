import 'package:asn1lib/asn1lib.dart';
void main() {
  try {
    var oid = ASN1ObjectIdentifier.fromComponentString('2.25.293029629918709742181702189012786017422');
    print(oid.encodedBytes);
  } catch (e) {
    print('Failed: $e');
  }
}
