import 'dart:convert';

/// JSON helpers.
class JsonUtil {
  static String encode(Object? value) => jsonEncode(value);
  static dynamic decode(String json) => jsonDecode(json);

  static Map<String, dynamic> safeMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    return {};
  }
}
