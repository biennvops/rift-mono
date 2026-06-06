import 'dart:typed_data';

class ClipboardMetadata {
  final String contentType;
  final int byteSize;
  final String sha256;

  ClipboardMetadata({
    required this.contentType,
    required this.byteSize,
    required this.sha256,
  });
}

class ClipboardContent {
  final String contentType;
  final Uint8List contentBytes;
  final String sha256;

  ClipboardContent({
    required this.contentType,
    required this.contentBytes,
    required this.sha256,
  });
}

abstract class ClipboardService {
  Future<void> setClipboardContent(ClipboardContent content);
  Future<ClipboardContent?> getClipboardContent();
  Stream<ClipboardMetadata> get onClipboardChanged;
}
