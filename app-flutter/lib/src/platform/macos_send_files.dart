import 'package:flutter/services.dart';

class MacOSSendFiles {
  static const MethodChannel _channel = MethodChannel('rift/macos/send_files');
  static const String callbackMethod = 'sendFilesSelected';

  static Future<List<Map<String, String>>> pickSendFiles() async {
    final response =
        await _channel.invokeMethod<List<Object?>>('pickSendFiles');
    return _parseItems(response);
  }

  static void setMethodCallHandler(
      Future<dynamic> Function(MethodCall call)? handler) {
    _channel.setMethodCallHandler(handler);
  }

  static List<Map<String, String>> parseCallbackArguments(dynamic arguments) {
    if (arguments is List<Object?>) {
      return _parseItems(arguments);
    }
    if (arguments is List) {
      return _parseItems(arguments.cast<Object?>());
    }
    return const <Map<String, String>>[];
  }

  static List<Map<String, String>> _parseItems(List<Object?>? rawItems) {
    if (rawItems == null) {
      return const <Map<String, String>>[];
    }

    return rawItems
        .whereType<Map>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(
              key.toString(),
              value?.toString() ?? '',
            ),
          ),
        )
        .where(
          (item) =>
              (item['localPath'] ?? '').isNotEmpty &&
              (item['fileName'] ?? '').isNotEmpty,
        )
        .toList(growable: false);
  }
}
