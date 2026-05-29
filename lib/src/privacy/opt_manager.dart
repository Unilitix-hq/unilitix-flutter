import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's opt-out preference.
class OptManager {
  static const _key = 'unilitix_opted_out';

  bool _optedOut = false;
  bool get isOptedOut => _optedOut;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _optedOut = prefs.getBool(_key) ?? false;
  }

  Future<void> optOut() async {
    _optedOut = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  Future<void> optIn() async {
    _optedOut = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, false);
  }
}
