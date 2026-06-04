import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'app_session_service.dart';

class BackendControlApiException implements Exception {
  final String message;

  const BackendControlApiException(this.message);

  @override
  String toString() => message;
}

class IndoorFarmingPinSetting {
  final bool isEnabled;
  final bool hasPin;
  final int unlockDurationMinutes;
  final DateTime? updatedAt;
  final String? updatedByName;

  const IndoorFarmingPinSetting({
    required this.isEnabled,
    required this.hasPin,
    required this.unlockDurationMinutes,
    this.updatedAt,
    this.updatedByName,
  });

  factory IndoorFarmingPinSetting.fromJson(Map<String, dynamic> json) {
    return IndoorFarmingPinSetting(
      isEnabled: json['is_enabled'] == true,
      hasPin: json['has_pin'] == true,
      unlockDurationMinutes:
          (json['unlock_duration_minutes'] as num?)?.toInt() ?? 30,
      updatedAt: json['updated_at'] is String
          ? DateTime.tryParse(json['updated_at'].toString())?.toLocal()
          : null,
      updatedByName: json['updated_by_name']?.toString(),
    );
  }
}

class IndoorFarmingGrantCandidate {
  final int id;
  final String name;
  final String email;
  final String role;
  final bool isActive;

  const IndoorFarmingGrantCandidate({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
  });

  factory IndoorFarmingGrantCandidate.fromJson(Map<String, dynamic> json) {
    return IndoorFarmingGrantCandidate(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '-',
      email: json['email']?.toString() ?? '-',
      role: json['role']?.toString() ?? 'user',
      isActive: json['is_active'] == true,
    );
  }
}

class IndoorFarmingAccessGrantItem {
  final int id;
  final int userId;
  final String userName;
  final String userEmail;
  final String userRole;
  final bool userIsActive;
  final String grantedByName;
  final DateTime? createdAt;

  const IndoorFarmingAccessGrantItem({
    required this.id,
    required this.userId,
    required this.userName,
    required this.userEmail,
    required this.userRole,
    required this.userIsActive,
    required this.grantedByName,
    this.createdAt,
  });

  factory IndoorFarmingAccessGrantItem.fromJson(Map<String, dynamic> json) {
    return IndoorFarmingAccessGrantItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      userId: (json['user_id'] as num?)?.toInt() ?? 0,
      userName: json['user_name']?.toString() ?? '-',
      userEmail: json['user_email']?.toString() ?? '-',
      userRole: json['user_role']?.toString() ?? 'user',
      userIsActive: json['user_is_active'] == true,
      grantedByName: json['granted_by_name']?.toString() ?? '-',
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'].toString())?.toLocal()
          : null,
    );
  }
}

class IndoorFarmingAdminConfig {
  final IndoorFarmingPinSetting pinSetting;
  final List<IndoorFarmingGrantCandidate> grantCandidates;
  final List<IndoorFarmingAccessGrantItem> accessGrants;

  const IndoorFarmingAdminConfig({
    required this.pinSetting,
    required this.grantCandidates,
    required this.accessGrants,
  });

  factory IndoorFarmingAdminConfig.fromJson(Map<String, dynamic> json) {
    final rawPin = json['pin_setting'];
    final rawCandidates = json['grant_candidates'];
    final rawGrants = json['access_grants'];

    return IndoorFarmingAdminConfig(
      pinSetting: rawPin is Map<String, dynamic>
          ? IndoorFarmingPinSetting.fromJson(rawPin)
          : const IndoorFarmingPinSetting(
              isEnabled: false,
              hasPin: false,
              unlockDurationMinutes: 30,
            ),
      grantCandidates: rawCandidates is List
          ? rawCandidates
              .map((item) => item is Map<String, dynamic>
                  ? IndoorFarmingGrantCandidate.fromJson(item)
                  : null)
              .whereType<IndoorFarmingGrantCandidate>()
              .toList()
          : const [],
      accessGrants: rawGrants is List
          ? rawGrants
              .map((item) => item is Map<String, dynamic>
                  ? IndoorFarmingAccessGrantItem.fromJson(item)
                  : null)
              .whereType<IndoorFarmingAccessGrantItem>()
              .toList()
          : const [],
    );
  }
}

class BackendControlApiService {
  String _baseUrl() {
    final base = AppConfig.normalizeApiV1Base();
    if (base.isEmpty) {
      throw const BackendControlApiException(
        'BUNCOP_API_BASE belum dikonfigurasi.',
      );
    }
    return base;
  }

  Future<IndoorFarmingAdminConfig> fetchIndoorFarmingConfig() async {
    final uri = Uri.parse('${_baseUrl()}/admin/indoor-farming/access-config');
    final response = await http
        .get(uri, headers: AppSessionService.buildAuthHeaders(json: false))
        .timeout(const Duration(seconds: 15));

    final body = _decodeJsonSafe(response.body);
    if (response.statusCode >= 400) {
      throw BackendControlApiException(
        body['message']?.toString() ??
            'Gagal memuat pengaturan backend indoor farming.',
      );
    }

    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const BackendControlApiException(
        'Respons pengaturan backend indoor farming tidak valid.',
      );
    }

    return IndoorFarmingAdminConfig.fromJson(data);
  }

  Future<String> saveIndoorFarmingPin({
    String? pin,
    String? pinConfirmation,
    required int unlockDurationMinutes,
    bool disablePin = false,
  }) async {
    final uri = Uri.parse('${_baseUrl()}/admin/indoor-farming/pin');
    final response = await http
        .post(
          uri,
          headers: AppSessionService.buildAuthHeaders(),
          body: jsonEncode(<String, dynamic>{
            'pin': (pin ?? '').trim().isEmpty ? null : pin?.trim(),
            'pin_confirmation': (pinConfirmation ?? '').trim().isEmpty
                ? null
                : pinConfirmation?.trim(),
            'unlock_duration_minutes': unlockDurationMinutes,
            'disable_pin': disablePin,
          }),
        )
        .timeout(const Duration(seconds: 15));

    final body = _decodeJsonSafe(response.body);
    if (response.statusCode >= 400) {
      final errors = body['errors'];
      if (errors is Map<String, dynamic>) {
        final first = errors.values
            .whereType<List>()
            .expand((item) => item)
            .map((item) => item.toString())
            .firstWhere((_) => true, orElse: () => '');
        if (first.isNotEmpty) {
          throw BackendControlApiException(first);
        }
      }
      throw BackendControlApiException(
        body['message']?.toString() ??
            'Gagal menyimpan pengaturan PIN indoor farming.',
      );
    }

    return body['message']?.toString() ??
        'Pengaturan PIN indoor farming berhasil diperbarui.';
  }

  Future<String> createIndoorFarmingGrant(int userId) async {
    final uri =
        Uri.parse('${_baseUrl()}/admin/indoor-farming/access-grants');
    final response = await http
        .post(
          uri,
          headers: AppSessionService.buildAuthHeaders(),
          body: jsonEncode(<String, dynamic>{'user_id': userId}),
        )
        .timeout(const Duration(seconds: 15));

    final body = _decodeJsonSafe(response.body);
    if (response.statusCode >= 400) {
      throw BackendControlApiException(
        body['message']?.toString() ?? 'Gagal memberi akses penuh.',
      );
    }

    return body['message']?.toString() ?? 'Akses penuh berhasil diberikan.';
  }

  Future<String> revokeIndoorFarmingGrant(int grantId) async {
    final uri =
        Uri.parse('${_baseUrl()}/admin/indoor-farming/access-grants/$grantId');
    final response = await http
        .delete(uri, headers: AppSessionService.buildAuthHeaders())
        .timeout(const Duration(seconds: 15));

    final body = _decodeJsonSafe(response.body);
    if (response.statusCode >= 400) {
      throw BackendControlApiException(
        body['message']?.toString() ?? 'Gagal mencabut akses penuh.',
      );
    }

    return body['message']?.toString() ?? 'Akses penuh berhasil dicabut.';
  }

  Map<String, dynamic> _decodeJsonSafe(String body) {
    if (body.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{};
  }
}
