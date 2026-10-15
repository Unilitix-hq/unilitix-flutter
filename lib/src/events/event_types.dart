/// Event type constants matching the Unilitix backend schema.
class EventTypes {
  static const String tap = 'TAP';
  static const String navigate = 'NAV';
  static const String rageTap = 'RAGE_TAP';
  static const String crash = 'CRASH';

  /// A handled or non-fatal error (e.g. a Flutter framework error caught by
  /// FlutterError.onError). Does not mark the session as crashed.
  static const String exception = 'EXCEPTION';
  static const String custom = 'CUSTOM';
  static const String sessionStart = 'SESSION_START';
  static const String scroll = 'SCROLL';
}
