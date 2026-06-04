import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'app_session_service.dart';
import 'indoor_farming_mqtt_service.dart';

class IndoorFarmingAccessApiException implements Exception {
  final String message;

  const IndoorFarmingAccessApiException(this.message);

  @override
  String toString() => message;
}

class IndoorFarmingControlAccess {
  final String role;
  final bool requiresPin;
  final bool canManageControls;
  final bool bypassGranted;
  final DateTime? unlockExpiresAt;
  final int unlockDurationMinutes;

  const IndoorFarmingControlAccess({
    required this.role,
    required this.requiresPin,
    required this.canManageControls,
    required this.bypassGranted,
    required this.unlockDurationMinutes,
    this.unlockExpiresAt,
  });

  bool get isPrivilegedRole => role == 'admin' || role == 'super_admin';

  factory IndoorFarmingControlAccess.fromJson(Map<String, dynamic> json) {
    return IndoorFarmingControlAccess(
      role: json['role']?.toString() ?? 'user',
      requiresPin: json['requiresPin'] == true,
      canManageControls: json['canManageControls'] == true,
      bypassGranted: json['bypassGranted'] == true,
      unlockDurationMinutes:
          (json['unlockDurationMinutes'] as num?)?.toInt() ?? 30,
      unlockExpiresAt: json['unlockExpiresAt'] is String
          ? DateTime.tryParse(json['unlockExpiresAt'].toString())?.toLocal()
          : null,
    );
  }

  factory IndoorFarmingControlAccess.fallback() {
    final role = (AppSessionService.role ?? 'user').trim().toLowerCase();
    final privileged = role == 'admin' || role == 'super_admin';
    return IndoorFarmingControlAccess(
      role: role.isEmpty ? 'user' : role,
      requiresPin: !privileged,
      canManageControls: privileged,
      bypassGranted: false,
      unlockDurationMinutes: 30,
    );
  }
}

class IndoorFarmingAccessSnapshot {
  final IndoorFarmingControlAccess access;
  final IndoorAutoConfig? config;

  const IndoorFarmingAccessSnapshot({
    required this.access,
    this.config,
  });
}

class IndoorFarmingAccessApiService {
  String _resolveBaseUrl() {
    final base = AppConfig.normalizeApiV1Base();
    if (base.isEmpty) {
      throw StateError(
        'BUNCOP_API_BASE belum dikonfigurasi untuk akses indoor farming.',
      );
    }
    return base;
  }

  Future<IndoorFarmingAccessSnapshot> fetchAccessSnapshot() async {
    try {
      if ((AppSessionService.token ?? '').trim().isEmpty) {
        await AppSessionService.restoreSession();
      }
      final uri = Uri.parse(
        '${_resolveBaseUrl()}/indoor-farming/control-access?device_id=${Uri.encodeQueryComponent(IndoorFarmingMqttService.defaultDeviceId)}',
      );
      final response = await http
          .get(
            uri,
            headers: AppSessionService.buildAuthHeaders(json: false),
          )
          .timeout(const Duration(seconds: 10));

      final body = _decodeJsonSafe(response.body);
      if (response.statusCode >= 400) {
        throw IndoorFarmingAccessApiException(
          body['message']?.toString() ?? 'Gagal membaca akses indoor farming.',
        );
      }

      final access = body['access'];
      if (access is! Map<String, dynamic>) {
        throw const IndoorFarmingAccessApiException(
          'Respons akses indoor farming tidak valid.',
        );
      }

      final config = body['config'];
      return IndoorFarmingAccessSnapshot(
        access: IndoorFarmingControlAccess.fromJson(access),
        config: config is Map<String, dynamic>
            ? IndoorAutoConfig.fromJson(config)
            : null,
      );
    } on StateError catch (e) {
      throw IndoorFarmingAccessApiException(e.message);
    } on TimeoutException {
      throw const IndoorFarmingAccessApiException('Koneksi timeout ke server.');
    } on IndoorFarmingAccessApiException {
      rethrow;
    } catch (_) {
      throw const IndoorFarmingAccessApiException(
        'Tidak dapat terhubung ke server indoor farming.',
      );
    }
  }

  Future<IndoorFarmingControlAccess> fetchAccess() async {
    final snapshot = await fetchAccessSnapshot();
    return snapshot.access;
  }

  Future<IndoorAutoConfig> fetchConfig() async {
    try {
      if ((AppSessionService.token ?? '').trim().isEmpty) {
        await AppSessionService.restoreSession();
      }
      final uri = Uri.parse('${_resolveBaseUrl()}/indoor-farming/config');
      final response = await http
          .get(
            uri,
            headers: AppSessionService.buildAuthHeaders(json: false),
          )
          .timeout(const Duration(seconds: 10));

      final body = _decodeJsonSafe(response.body);
      if (response.statusCode >= 400) {
        throw IndoorFarmingAccessApiException(
          body['message']?.toString() ??
              'Gagal membaca konfigurasi indoor farming.',
        );
      }

      final config = body['config'];
      if (config is! Map<String, dynamic>) {
        throw const IndoorFarmingAccessApiException(
          'Respons konfigurasi indoor farming tidak valid.',
        );
      }

      return IndoorAutoConfig.fromJson(config);
    } on StateError catch (e) {
      throw IndoorFarmingAccessApiException(e.message);
    } on TimeoutException {
      throw const IndoorFarmingAccessApiException('Koneksi timeout ke server.');
    } on IndoorFarmingAccessApiException {
      rethrow;
    } catch (_) {
      throw const IndoorFarmingAccessApiException(
        'Tidak dapat terhubung ke server indoor farming.',
      );
    }
  }

  Future<IndoorFarmingAccessSnapshot> unlockControlsSnapshot(
    String pin, {
    String target = 'config_control',
  }) async {
    try {
      if ((AppSessionService.token ?? '').trim().isEmpty) {
        await AppSessionService.restoreSession();
      }
      final uri = Uri.parse('${_resolveBaseUrl()}/indoor-farming/unlock');
      final response = await http
          .post(
            uri,
            headers: AppSessionService.buildAuthHeaders(),
            body: jsonEncode(<String, dynamic>{
              'pin': pin,
              'target': target,
              'device_id': IndoorFarmingMqttService.defaultDeviceId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final body = _decodeJsonSafe(response.body);
      if (response.statusCode >= 400) {
        final errors = body['errors'];
        if (errors is Map && errors['pin'] is List && (errors['pin'] as List).isNotEmpty) {
          throw IndoorFarmingAccessApiException(
            (errors['pin'] as List).first.toString(),
          );
        }
        throw IndoorFarmingAccessApiException(
          body['message']?.toString() ??
              'Gagal membuka akses indoor farming (HTTP ${response.statusCode}).',
        );
      }

      final access = body['access'];
      if (access is! Map<String, dynamic>) {
        throw const IndoorFarmingAccessApiException(
          'Respons unlock indoor farming tidak valid.',
        );
      }

      final config = body['config'];
      return IndoorFarmingAccessSnapshot(
        access: IndoorFarmingControlAccess.fromJson(access),
        config: config is Map<String, dynamic>
            ? IndoorAutoConfig.fromJson(config)
            : null,
      );
    } on StateError catch (e) {
      throw IndoorFarmingAccessApiException(e.message);
    } on TimeoutException {
      throw const IndoorFarmingAccessApiException('Koneksi timeout ke server.');
    } on IndoorFarmingAccessApiException {
      rethrow;
    } catch (_) {
      throw const IndoorFarmingAccessApiException(
        'Tidak dapat menghubungi server unlock indoor farming.',
      );
    }
  }

  Future<IndoorFarmingControlAccess> unlockControls(
    String pin, {
    String target = 'config_control',
  }) async {
    final snapshot = await unlockControlsSnapshot(pin, target: target);
    return snapshot.access;
  }

  Map<String, dynamic> _decodeJsonSafe(String body) {
    if (body.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }
}
