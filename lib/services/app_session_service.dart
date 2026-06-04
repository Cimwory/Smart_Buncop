import '../config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSessionService {
  static const String _keyUserId = 'app_session.user_id';
  static const String _keyRole = 'app_session.role';
  static const String _keyEmail = 'app_session.email';
  static const String _keyToken = 'app_session.token';
  static const String _keyApiBase = 'app_session.api_base';

  static int? userId;
  static String? role;
  static String? email;
  static String? token;

  static Future<void> setSession({
    int? id,
    required String roleValue,
    String? emailValue,
    String? tokenValue,
  }) async {
    userId = id;
    role = roleValue;
    email = emailValue;
    token = tokenValue;

    final prefs = await SharedPreferences.getInstance();
    final currentApiBase = AppConfig.normalizeApiV1Base();
    if (id != null) {
      await prefs.setInt(_keyUserId, id);
    } else {
      await prefs.remove(_keyUserId);
    }
    await prefs.setString(_keyRole, roleValue);
    if (emailValue != null && emailValue.isNotEmpty) {
      await prefs.setString(_keyEmail, emailValue);
    } else {
      await prefs.remove(_keyEmail);
    }
    if (tokenValue != null && tokenValue.isNotEmpty) {
      await prefs.setString(_keyToken, tokenValue);
    } else {
      await prefs.remove(_keyToken);
    }
    if (currentApiBase.isNotEmpty) {
      await prefs.setString(_keyApiBase, currentApiBase);
    } else {
      await prefs.remove(_keyApiBase);
    }
  }

  static Future<bool> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final currentApiBase = AppConfig.normalizeApiV1Base();
    final savedApiBase = prefs.getString(_keyApiBase) ?? '';
    if (savedApiBase.isNotEmpty &&
        currentApiBase.isNotEmpty &&
        savedApiBase != currentApiBase) {
      await clear();
      return false;
    }
    final savedToken = prefs.getString(_keyToken) ?? '';
    final savedRole = prefs.getString(_keyRole) ?? '';
    if (savedToken.isEmpty || savedRole.isEmpty) {
      clearMemory();
      return false;
    }

    userId = prefs.getInt(_keyUserId);
    role = savedRole;
    email = prefs.getString(_keyEmail);
    token = savedToken;
    return true;
  }

  static Map<String, String> buildAuthHeaders({bool json = true}) {
    final headers = <String, String>{};
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    if (token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static void clearMemory() {
    userId = null;
    role = null;
    email = null;
    token = null;
  }

  static Future<void> clear() async {
    clearMemory();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyRole);
    await prefs.remove(_keyEmail);
    await prefs.remove(_keyToken);
    await prefs.remove(_keyApiBase);
  }
}
