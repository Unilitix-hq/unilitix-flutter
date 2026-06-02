/// JSON helpers.
class JsonUtil {
  static String toRfc3339(int milliseconds) {
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
      isUtc: true,
    ).toIso8601String();
  }
}
