class RiftConstants {
  static const String protocolVersion = '0.1-draft';
  static const String implementationId = 'riftd-dart/0.1.0';
  static const List<Map<String, dynamic>> capabilities = [
    {'name': 'clipboard.offer_fetch', 'version': 1},
    {'name': 'file.transfer', 'version': 1},
    {'name': 'presence.basic', 'version': 1},
    {'name': 'operation.lifecycle', 'version': 1},
    {'name': 'security.event_log', 'version': 1},
  ];
}
