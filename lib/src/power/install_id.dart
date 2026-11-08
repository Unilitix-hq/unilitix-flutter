import 'package:shared_preferences/shared_preferences.dart';

/// The install id the power-outage device hash is derived from (with a
/// salt that rotates daily, see `powerDeviceHash`); it never leaves the
/// device. Same storage key as 2.x, so an upgraded install keeps its id.
Future<String> powerInstallId() async {
  const key = 'unilitix_install_id';
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    await prefs.setString(key, id);
    return id;
  } catch (_) {
    return 'unknown';
  }
}
