import 'dart:convert';

import 'package:http/http.dart' as http;
import '../config/app_config.dart';

import 'app_session_service.dart';
import 'auth_api_service.dart';

class AccessUser {
  final int id;
  final String name;
  final String email;
  final String role;
  final bool isActive;
  final String authProvider;

  const AccessUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
    required this.authProvider,
  });

  factory AccessUser.fromJson(Map<String, dynamic> json) {
    final rawActive = json['is_active'];
    final parsedActive = rawActive is bool
        ? rawActive
        : (rawActive is num ? rawActive != 0 : rawActive?.toString() != '0');

    return AccessUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '-',
      email: json['email']?.toString() ?? '-',
      role: json['role']?.toString() ?? 'user',
      isActive: parsedActive,
      authProvider: json['auth_provider']?.toString() ?? 'local',
    );
  }
}

class UserAccessApiService {
  static String get _baseUrl => AppConfig.requireApiBase();

  Future<List<String>> listRoles() async {
    final uri = Uri.parse('$_baseUrl/auth/roles');
    final response = await http.get(
      uri,
      headers: AppSessionService.buildAuthHeaders(json: false),
    );

    final body = _decodeJson(response.body);
    if (response.statusCode >= 400) {
      throw AuthApiException(body['message']?.toString() ?? 'Gagal memuat roles');
    }

    final raw = body['data'];
    if (raw is! List) return const ['super_admin', 'admin', 'user'];
    final roles = raw.map((e) => e.toString()).toList();
    if (roles.isEmpty) return const ['super_admin', 'admin', 'user'];
    return roles;
  }

  Future<List<AccessUser>> listUsers() async {
    final uri = Uri.parse('$_baseUrl/auth/users');
    final response = await http.get(
      uri,
      headers: AppSessionService.buildAuthHeaders(json: false),
    );

    final body = _decodeJson(response.body);
    if (response.statusCode >= 400) {
      throw AuthApiException(body['message']?.toString() ?? 'Gagal memuat user');
    }

    final raw = body['data'];
    if (raw is! List) return const [];
    return raw
        .map((item) =>
            item is Map<String, dynamic> ? AccessUser.fromJson(item) : null)
        .whereType<AccessUser>()
        .toList();
  }

  Future<void> updateUserRole({
    required int userId,
    required String role,
  }) async {
    final uri = Uri.parse('$_baseUrl/auth/users/$userId/role');
    final response = await http.patch(
      uri,
      headers: AppSessionService.buildAuthHeaders(),
      body: jsonEncode({'role': role}),
    );

    final body = _decodeJson(response.body);
    if (response.statusCode >= 400) {
      throw AuthApiException(body['message']?.toString() ?? 'Gagal memperbarui role');
    }
  }

  Future<void> updateUserActive({
    required int userId,
    required bool isActive,
  }) async {
    final uri = Uri.parse('$_baseUrl/auth/users/$userId/active');
    final response = await http.patch(
      uri,
      headers: AppSessionService.buildAuthHeaders(),
      body: jsonEncode({'is_active': isActive}),
    );

    final body = _decodeJson(response.body);
    if (response.statusCode >= 400) {
      throw AuthApiException(
        body['message']?.toString() ?? 'Gagal memperbarui status user',
      );
    }
  }

  Map<String, dynamic> _decodeJson(String body) {
    if (body.isEmpty) return {};
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : {};
  }
}
