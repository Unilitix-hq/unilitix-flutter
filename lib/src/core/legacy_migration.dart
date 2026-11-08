import 'package:shared_preferences/shared_preferences.dart';

import '../consent.dart';

/// One-time carry-over of the consent decision 2.x kept in Dart.
///
/// Until 2.7.4 the Dart SDK persisted consent itself
/// (`SharedPreferences`: `unilitix_consent`, and before 2.1
/// `unilitix_opted_out`). From 3.0.0 the native SDK owns it. On the first
/// launch after the upgrade the stored decision is handed to the native SDK
/// (as the initial state and as a `setConsent` sent before any other call),
/// so a user who denied under 2.x is never collected from, then the old
/// keys are removed. The 2.x anonymous and user ids are not carried over
/// (see MIGRATION.md).
class LegacyConsent {
  static const String consentKey = 'unilitix_consent';
  static const String optedOutKey = 'unilitix_opted_out';

  /// The decision 2.x stored, or null when there is none (or storage fails).
  static Future<UnilitixConsent?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = consentFromWireName(prefs.getString(consentKey));
      if (stored != null) return stored;
      if (prefs.getBool(optedOutKey) == true) return UnilitixConsent.denied;
    } catch (_) {}
    return null;
  }

  /// Forgets the 2.x decision once the native SDK has it.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(consentKey);
      await prefs.remove(optedOutKey);
    } catch (_) {}
  }
}
