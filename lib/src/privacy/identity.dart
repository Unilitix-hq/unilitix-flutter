import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/ids.dart';

/// Manages anonymous ID, user ID, install ID, and user traits.
class Identity {
  static const _keyUserId = 'unilitix_user_id';
  static const _keyAnonId = 'unilitix_anon_id';
  static const _keyInstallId = 'unilitix_install_id';

  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  String? _anonymousId;
  String? _userId;
  String? _installId;
  Map<String, dynamic> _userTraits = {};

  String get anonymousId => _anonymousId ?? 'unknown';
  String? get userId => _userId;
  String get installId => _installId ?? 'unknown';
  Map<String, dynamic> get userTraits => Map.unmodifiable(_userTraits);

  Future<void> initialize() async {
    await _loadInstallId();
    await _loadOrGenerateAnonId();
    await _loadUserId();
  }

  Future<void> _loadInstallId() async {
    try {
      _installId = await _secure.read(key: _keyInstallId);
      if (_installId == null) {
        _installId = DateTime.now().millisecondsSinceEpoch.toString();
        await _secure.write(key: _keyInstallId, value: _installId!);
      }
    } catch (e) {
      _installId = DateTime.now().millisecondsSinceEpoch.toString();
    }
  }

  Future<void> _loadOrGenerateAnonId() async {
    try {
      _anonymousId = await _secure.read(key: _keyAnonId);
    } catch (_) {
      // Fallback to shared_preferences if secure storage unavailable
      final prefs = await SharedPreferences.getInstance();
      _anonymousId = prefs.getString(_keyAnonId);
    }

    // SDK < 2.1 derived this id from Android's Build.ID, which is the firmware
    // fingerprint shared by every device on the same ROM, so unrelated users
    // collapsed into one anonymous id. Replace any legacy (non-UUID) value once.
    if (_anonymousId == null || !isValidAnonymousId(_anonymousId!)) {
      _anonymousId = generateAnonymousId();
      await _persistAnonId(_anonymousId!);
    }
  }

  /// Anonymous ids are random UUID v4s: unique per install, never derived
  /// from hardware or OS identifiers, rotated by [reset].
  static String generateAnonymousId() => generateUuidV4();

  static final RegExp _uuidV4 = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  @visibleForTesting
  static bool isValidAnonymousId(String id) => _uuidV4.hasMatch(id);

  Future<void> _persistAnonId(String id) async {
    try {
      await _secure.write(key: _keyAnonId, value: id);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAnonId, id);
    }
  }

  Future<void> _loadUserId() async {
    try {
      _userId = await _secure.read(key: _keyUserId);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      _userId = prefs.getString(_keyUserId);
    }
  }

  Future<void> setUserId(String userId, {Map<String, dynamic>? traits}) async {
    _userId = userId;
    if (traits != null) setTraits(traits);
    try {
      await _secure.write(key: _keyUserId, value: userId);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyUserId, userId);
    }
  }

  void setTraits(Map<String, dynamic> traits) {
    _userTraits = {..._userTraits, ...traits};
  }

  Future<void> reset() async {
    _userId = null;
    _userTraits = {};
    try {
      await _secure.delete(key: _keyUserId);
      await _secure.delete(key: _keyAnonId);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyUserId);
      await prefs.remove(_keyAnonId);
    }
    // A fresh random id: the pre-logout and post-logout users are unlinkable.
    _anonymousId = generateAnonymousId();
    await _persistAnonId(_anonymousId!);
  }
}
