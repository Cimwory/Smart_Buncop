import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'app_session_service.dart';

class AuthApiException implements Exception {
  final String message;
  const AuthApiException(this.message);

  @override
  String toString() => message;
}

class LoginUser {
  final int id;
  final String name;
  final String email;
  final String role;

  const LoginUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
  });

  factory LoginUser.fromJson(Map<String, dynamic> json) {
    return LoginUser(
      id: (json['id'] as num).toInt(),
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      role: json['role']?.toString() ?? 'user',
    );
  }
}

class LoginResult {
  final LoginUser user;
  final String token;
  final Map<String, dynamic>? sso;

  const LoginResult({
    required this.user,
    required this.token,
    this.sso,
  });
}

class AuthApiService {
  String _resolveBaseUrl() {
    try {
      return AppConfig.requireApiBase();
    } on StateError catch (e) {
      throw AuthApiException(e.message);
    }
  }

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/auth/login');
      final response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final body = _decodeJson(response.body);

      if (response.statusCode >= 400) {
        final message = body['message']?.toString() ?? 'Login gagal';
        throw AuthApiException(message);
      }

      final userJson = body['user'];
      final token = body['token']?.toString() ?? '';
      if (userJson is! Map<String, dynamic> || token.isEmpty) {
        throw const AuthApiException('Respons login tidak valid (token/user kosong)');
      }

      return LoginResult(
        user: LoginUser.fromJson(userJson),
        token: token,
      );
    } on TimeoutException {
      throw const AuthApiException('Koneksi timeout ke server');
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException('Tidak dapat terhubung ke server login');
    }
  }

  Future<void> register({
    required String name,
    required String email,
    required String password,
    String role = 'user',
  }) async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/auth/register');
      final response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              'email': email,
              'password': password,
              'role': role,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final body = _decodeJson(response.body);

      if (response.statusCode >= 400) {
        final message = body['message']?.toString() ?? 'Register gagal';
        throw AuthApiException(message);
      }
    } on TimeoutException {
      throw const AuthApiException('Koneksi timeout ke server');
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException('Tidak dapat terhubung ke server register');
    }
  }

  Future<String> getSsoAuthUrl({String channel = 'mobile'}) async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/auth/sso/start')
          .replace(queryParameters: {'channel': channel});
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      final body = _decodeJson(response.body);

      if (response.statusCode >= 400) {
        final message = body['message']?.toString() ?? 'Gagal memulai SSO';
        throw AuthApiException(message);
      }

      final authUrl = body['auth_url']?.toString() ?? '';
      if (authUrl.isEmpty) {
        throw const AuthApiException('Auth URL SSO tidak tersedia');
      }

      return authUrl;
    } on TimeoutException {
      throw const AuthApiException('Koneksi timeout ke server');
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException('Tidak dapat memulai login SSO');
    }
  }

  Future<LoginResult> exchangeSsoCode({required String code}) async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/auth/sso/exchange');
      final response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code}),
          )
          .timeout(const Duration(seconds: 10));

      final body = _decodeJson(response.body);

      if (response.statusCode >= 400) {
        final message = body['message']?.toString() ?? 'Pertukaran kode SSO gagal';
        throw AuthApiException(message);
      }

      final userJson = body['user'];
      final token = body['token']?.toString() ?? '';
      if (userJson is! Map<String, dynamic> || token.isEmpty) {
        throw const AuthApiException('Respons pertukaran SSO tidak valid');
      }

      final sso = body['sso'];
      return LoginResult(
        user: LoginUser.fromJson(userJson),
        token: token,
        sso: sso is Map<String, dynamic> ? sso : null,
      );
    } on TimeoutException {
      throw const AuthApiException('Koneksi timeout ke server');
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException('Tidak dapat terhubung ke server SSO');
    }
  }

  Future<LoginResult> exchangeSsoMobileToken({
    required String idToken,
    String? accessToken,
    String? refreshToken,
    int? expiresIn,
    String? tokenType,
  }) async {
    final payload = <String, dynamic>{
      'id_token': idToken,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': expiresIn,
      'token_type': tokenType,
    }..removeWhere((key, value) => value == null);

    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/auth/sso/mobile-exchange');
      final response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      final body = _decodeJson(response.body);

      if (response.statusCode >= 400) {
        final message =
            body['message']?.toString() ?? 'Pertukaran token SSO gagal';
        throw AuthApiException(message);
      }

      final userJson = body['user'];
      final token = body['token']?.toString() ?? '';
      if (userJson is! Map<String, dynamic> || token.isEmpty) {
        throw const AuthApiException('Respons pertukaran token SSO tidak valid');
      }

      final sso = body['sso'];
      return LoginResult(
        user: LoginUser.fromJson(userJson),
        token: token,
        sso: sso is Map<String, dynamic> ? sso : null,
      );
    } on TimeoutException {
      throw const AuthApiException('Koneksi timeout ke server');
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException('Tidak dapat terhubung ke server SSO');
    }
  }

  Future<void> logout({required String token}) async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/auth/logout');
      await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best-effort logout. Client session must still be cleared locally.
    }
  }

  Future<void> registerNotificationToken({
    required String token,
    required String platform,
    List<String> topics = const [],
    String? deviceName,
    String? deviceModel,
    String? appVersion,
  }) async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/notifications/token');
      final response = await http
          .post(
            uri,
            headers: AppSessionService.buildAuthHeaders(),
            body: jsonEncode({
              'token': token,
              'platform': platform,
              'device_name': deviceName,
              'device_model': deviceModel,
              'app_version': appVersion,
              'topics': topics,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 400) {
        final body = _decodeJson(response.body);
        throw AuthApiException(
          body['message']?.toString() ?? 'Registrasi token notifikasi gagal',
        );
      }
    } on TimeoutException {
      throw const AuthApiException('Koneksi timeout ke server');
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException('Tidak dapat menyimpan token notifikasi');
    }
  }

  Future<void> unregisterNotificationToken({required String token}) async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/notifications/token');
      await http
          .delete(
            uri,
            headers: AppSessionService.buildAuthHeaders(),
            body: jsonEncode({'token': token}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best-effort token cleanup.
    }
  }

  Future<String> getSsoLogoutUrl() async {
    try {
      final uri = Uri.parse('${_resolveBaseUrl()}/auth/sso/logout-url');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      final body = _decodeJson(response.body);

      if (response.statusCode >= 400) {
        final message = body['message']?.toString() ?? 'Gagal memulai logout SSO';
        throw AuthApiException(message);
      }

      final logoutUrl = body['logout_url']?.toString() ?? '';
      if (logoutUrl.isEmpty) {
        throw const AuthApiException('Logout URL SSO tidak tersedia');
      }

      return logoutUrl;
    } on TimeoutException {
      throw const AuthApiException('Koneksi timeout ke server');
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException('Tidak dapat memulai logout SSO');
    }
  }

  Map<String, dynamic> _decodeJson(String body) {
    if (body.isEmpty) return {};
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {};
  }
}
