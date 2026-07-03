
class RpcUtils {
  static String requireStringParam(Map<String, dynamic> params, String key) {
    final value = params[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError.value(value, key, 'must be a non-empty string');
    }
    return value;
  }

  static int requireIntParam(Map<String, dynamic> params, String key) {
    final value = params[key];
    if (value is! int) {
      throw ArgumentError.value(value, key, 'must be an integer');
    }
    return value;
  }

  static Map<String, dynamic> normalizeParams(Object? params) {
    if (params == null) {
      return <String, dynamic>{};
    }
    if (params is Map) {
      return params.map((key, value) => MapEntry(key.toString(), value));
    }
    throw ArgumentError.value(params, 'params', 'must be an object');
  }
}
