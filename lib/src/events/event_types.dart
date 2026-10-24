/// Event type constants matching the Unilitix backend schema. Each one must
/// appear in [SdkContract.eventTypes] (checked by test/sdk_contract_test.dart).
class EventTypes {
  static const String tap = 'TAP';

  /// Screen change. 2.1.3 and earlier sent the legacy 'NAV', which the
  /// server now rewrites to this.
  static const String navigate = 'NAVIGATE';
  static const String rageTap = 'RAGE_TAP';
  static const String crash = 'CRASH';

  /// A handled or non-fatal error (e.g. a Flutter framework error caught by
  /// FlutterError.onError). Does not mark the session as crashed.
  static const String exception = 'EXCEPTION';
  static const String custom = 'CUSTOM';

  /// The app stopped responding (Android 11+: an ANR the system killed the
  /// process for, reported on the next launch). Not a crash: does not mark
  /// the session crashed. Contract 1.3.0.
  static const String anr = 'ANR';
  static const String sessionStart = 'SESSION_START';
  static const String scroll = 'SCROLL';
}
