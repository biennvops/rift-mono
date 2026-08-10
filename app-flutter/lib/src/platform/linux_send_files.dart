import 'package:flutter/services.dart';

class LinuxSendFiles {
  static const MethodChannel _channel = MethodChannel('rift/linux/send_files');
  static const String callbackMethod = 'sendFilesSelected';

  static void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    _channel.setMethodCallHandler(handler);
  }

  static Future<List<Map<String, String>>> consumePendingItems() async {
    try {
      final response =
          await _channel.invokeMethod<List<Object?>>('consumePendingItems');
      return parseCallbackArguments(response);
    } on MissingPluginException {
      return const <Map<String, String>>[];
    }
  }

  static List<Map<String, String>> parseCallbackArguments(dynamic arguments) {
    if (arguments is! List) {
      return const <Map<String, String>>[];
    }

    return arguments
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
