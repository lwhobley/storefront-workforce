import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// A random id for this app install. Used for sign-in attempt limits and on each punch.
/// It identifies the install, not the person.
Future<String> deviceId() async {
  const key = 'sw.device_id.v1';
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null && existing.length >= 16) return existing;
    final created = const Uuid().v4();
    await prefs.setString(key, created);
    return created;
  } catch (_) {
    return const Uuid().v4();
  }
}
