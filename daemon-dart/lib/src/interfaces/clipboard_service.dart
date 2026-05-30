abstract class ClipboardService {
  Future<void> setClipboardContent(String content);
  Future<String?> getClipboardContent();
  Stream<String> get onClipboardChanged;
}
