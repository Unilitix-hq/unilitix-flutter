import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logger/logger.dart';

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

    if (_anonymousId == null) {
      _anonymousId = await _generateAnonId();
      try {
        await _secure.write(key: _keyAnonId, value: _anonymousId!);
      } catch (_) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyAnonId, _anonymousId!);
      }
    }
  }

  Future<String> _generateAnonId() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      String deviceId = 'unknown';

      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        deviceId = info.id;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        deviceId = info.identifierForVendor ?? 'unknown';
      }

      final input =
          '$deviceId${packageInfo.packageName}${packageInfo.buildNumber}';
      final hash = sha256.convert(utf8.encode(input));
      return hash.toString().substring(0, 24);
    } catch (e) {
      UnilitixLogger.w('Failed to generate anon ID — using fallback');
      return DateTime.now().millisecondsSinceEpoch.toRadixString(16);
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
    _anonymousId = await _generateAnonId();
    try {
      await _secure.write(key: _keyAnonId, value: _anonymousId!);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAnonId, _anonymousId!);
    }
  }
}
