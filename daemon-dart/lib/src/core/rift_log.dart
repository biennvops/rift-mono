import 'dart:developer' as developer;

/// Minimal logging shim for daemon-dart.
///
/// We avoid `print()` in production to reduce stdout spam and to make logs
/// easier to filter in environments like Android logcat.
class RiftLog {
  static const bool _isProduct = bool.fromEnvironment('dart.vm.product');

  static void debug(String message, {String name = 'rift'}) {
    if (_isProduct) return;
    developer.log(message, name: name, level: 500); // DEBUG
    _mirror('D', name, message);
  }

  static void info(String message, {String name = 'rift'}) {
    developer.log(message, name: name, level: 800); // INFO
    _mirror('I', name, message);
  }

  static void warn(String message, {String name = 'rift'}) {
    developer.log(message, name: name, level: 900); // WARNING
    _mirror('W', name, message);
  }

  static void error(
    String message, {
    String name = 'rift',
    Object? error,
    StackTrace? stackTrace,
  }) {
    developer.log(
      message,
      name: name,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    ); // SEVERE
    _mirror('E', name, error == null ? message : '$message error=$error');
  }

  /// `developer.log` output is only visible through the VM service, so debug
  /// builds also mirror to stdout, which reaches adb logcat / device syslog.
  static void _mirror(String level, String name, String message) {
    if (_isProduct) return;
    // ignore: avoid_print
    print('[$name/$level] $message');
  }
}
