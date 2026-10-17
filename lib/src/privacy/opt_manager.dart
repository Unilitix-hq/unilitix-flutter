import 'package:shared_preferences/shared_preferences.dart';

/// The user's consent to analytics and replay collection.
///
/// * [granted] — collect and upload (the default for apps that do not ask).
/// * [pending] — collect to the on-device queue but upload nothing, until the
///   app calls `Unilitix.setConsent(granted)` (then everything held is sent)
///   or `denied` (then everything held is deleted). This is the state to
///   start in for NDPR/GDPR apps that show a consent screen after launch.
/// * [denied] — collect nothing, upload nothing, and purge what is stored.
///   Equivalent to `optOut()`.
///
/// The decision is persisted, so a user who denied on a previous launch stays
/// denied until the app calls `setConsent` again.
enum UnilitixConsent { pending, granted, denied }

/// Persists the consent decision across launches.
class OptManager {
  static const _legacyKey = 'unilitix_opted_out';
  static const _key = 'unilitix_consent';

  UnilitixConsent _consent = UnilitixConsent.granted;

  UnilitixConsent get consent => _consent;

  /// True when nothing may be collected or uploaded.
  bool get isOptedOut => _consent == UnilitixConsent.denied;

  /// True when data is collected and held on-device but must not be uploaded.
  bool get isPending => _consent == UnilitixConsent.pending;

  /// True when uploads are allowed.
  bool get canUpload => _consent == UnilitixConsent.granted;

  /// Loads the persisted decision. [initial] is used only when the user has
  /// never decided on this device (first launch, or an app that upgraded from
  /// an SDK without consent states).
  Future<void> load({UnilitixConsent initial = UnilitixConsent.granted}) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    if (stored != null) {
      _consent = UnilitixConsent.values.firstWhere(
        (c) => c.name == stored,
        orElse: () => initial,
      );
      return;
    }
    // Pre-2.1 installs stored only the opt-out flag; honour it.
    if (prefs.getBool(_legacyKey) == true) {
      _consent = UnilitixConsent.denied;
      return;
    }
    _consent = initial;
  }

  Future<void> set(UnilitixConsent c) async {
    _consent = c;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, c.name);
    await prefs.setBool(_legacyKey, c == UnilitixConsent.denied);
  }

  Future<void> optOut() => set(UnilitixConsent.denied);

  Future<void> optIn() => set(UnilitixConsent.granted);
}
