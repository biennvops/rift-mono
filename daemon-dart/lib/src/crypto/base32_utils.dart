import 'dart:typed_data';

class Base32Utils {
  /// RFC 4648 Base32 encoder (no padding).
  static String encode(Uint8List data) {
    const String alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    int buffer = 0;
    int bitsLeft = 0;
    final result = StringBuffer();

    for (int i = 0; i < data.length; i++) {
      buffer = (buffer << 8) | data[i];
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        result.write(alphabet[(buffer >> (bitsLeft - 5)) & 0x1F]);
        bitsLeft -= 5;
      }
      // Clamp to valid bits — prevents integer overflow on Dart web (dart2js).
      buffer &= (1 << bitsLeft) - 1;
    }
    if (bitsLeft > 0) {
      result.write(alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }
    return result.toString();
  }
}

