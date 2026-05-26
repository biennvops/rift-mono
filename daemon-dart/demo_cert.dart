import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'lib/src/crypto/cert_builder.dart';

void main() {
  try {
    // 1. Sinh khóa ECDSA nền tảng (Prime256v1)
    var keyPair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    
    // 2. Tạo khóa Ed25519 giả định (32 bytes)
    var mockEd25519Key = Uint8List.fromList(List.generate(32, (i) => i));
    
    // 3. Sử dụng RiftCertBuilder đã hoàn thiện để sinh chứng chỉ
    String cert = RiftCertBuilder.generateSelfSignedCert(keyPair, mockEd25519Key);
    
    // In ra màn hình để pipe qua openssl
    print(cert);
  } catch (e, stack) {
    print('Error: $e\n$stack');
  }
}
