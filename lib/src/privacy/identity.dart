import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/ids.dart';

/// Manages anonymous ID, user ID, install ID, and user traits.
///
/// Ids are stored in `shared_preferences`. Until 2.1.0 they lived in
/// `flutter_secure_storage` (Keychain / Android Keystore), which cost every
/// host app a native plugin plus its known Keystore failure modes, for values
/// that are not secrets: a random UUID and the app's own user id. Installs
/// upgrading from ≤ 2.1.0 therefore receive a fresh anonymous id once; the
/// user id is restored by the app's next `identify()` call.
class Identity {
  static const _keyUserId = 'unilitix_user_id';
  static const _keyAnonId = 'unilitix_anon_id';
  static const _keyInstallId = 'unilitix_install_id';

  String? _anonymousId;
  String? _userId;
  String? _installId;
  Map<String, dynamic> _userTraits = {};

  String get anonymousId => _anonymousId ?? 'unknown';
  String? get userId => _userId;
  String get installId => _installId ?? 'unknown';
  Map<String, dynamic> get userTraits => Map.unmodifiable(_userTraits);

  Future<void> initialize() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // Storage unavailable: run with in-memory ids for this process.
    }
    _installId = prefs?.getString(_keyInstallId);
    if (_installId == null) {
      _installId = DateTime.now().millisecondsSinceEpoch.toString();
      await _put(prefs, _keyInstallId, _installId!);
    }

    _anonymousId = prefs?.getString(_keyAnonId);
    // SDK < 2.1 derived this id from Android's Build.ID, which is the firmware
    // fingerprint shared by every device on the same ROM, so unrelated users
    // collapsed into one anonymous id. Replace any legacy (non-UUID) value once.
    if (_anonymousId == null || !isValidAnonymousId(_anonymousId!)) {
      _anonymousId = generateAnonymousId();
      await _put(prefs, _keyAnonId, _anonymousId!);
    }

    _userId = prefs?.getString(_keyUserId);
  }

  /// Anonymous ids are random UUID v4s: unique per install, never derived
  /// from hardware or OS identifiers, rotated by [reset].
  static String generateAnonymousId() => generateUuidV4();

  static final RegExp _uuidV4 = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  @visibleForTesting
  static bool isValidAnonymousId(String id) => _uuidV4.hasMatch(id);

  static Future<void> _put(
      SharedPreferences? prefs, String key, String value) async {
    try {
      await prefs?.setString(key, value);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  static Future<void> _remove(SharedPreferences? prefs, String key) async {
    try {
      await prefs?.remove(key);
    } catch (_) {}
  }

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<void> setUserId(String userId, {Map<String, dynamic>? traits}) async {
    _userId = userId;
    if (traits != null) setTraits(traits);
    await _put(await _prefs(), _keyUserId, userId);
  }

  void setTraits(Map<String, dynamic> traits) {
    _userTraits = {..._userTraits, ...traits};
  }

  Future<void> reset() async {
    _userId = null;
    _userTraits = {};
    final prefs = await _prefs();
    await _remove(prefs, _keyUserId);
    // A fresh random id: the pre-logout and post-logout users are unlinkable.
    _anonymousId = generateAnonymousId();
    await _put(prefs, _keyAnonId, _anonymousId!);
  }
}
