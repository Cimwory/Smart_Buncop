import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

import 'app_session_service.dart';

class ActivityLoggerService {
  static String get _baseUrl => AppConfig.requireApiBase();
  static String get _userLogUrl => '$_baseUrl/activity-logs';
  static String get _systemLogUrl => '$_baseUrl/system/activity-logs';

  static String _formatLocalDateTime(DateTime value) {
    final local = value.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  static bool _shouldSkip({
    required String action,
    required String module,
  }) {
    final normalizedAction = action.trim().toLowerCase();
    final normalizedModule = module.trim().toLowerCase();

    if (normalizedAction.isEmpty) return true;

    if (normalizedAction.startsWith('screen.open')) return true;

    if (normalizedAction == 'monitoring.node.inspect' ||
        normalizedAction == 'page_visit' ||
        normalizedAction == 'navigation') {
      return true;
    }

    if (normalizedModule == 'navigation') return true;

    return false;
  }

  static Future<void> log({
    required String action,
    required String module,
    String? deviceId,
    String? description,
    Map<String, dynamic>? metadata,
  }) async {
    if (_shouldSkip(action: action, module: module)) {
      return;
    }

    final payload = <String, dynamic>{
      'action': action,
      'module': module,
      'device_id': deviceId,
      'description': description,
      'metadata': metadata,
      'performed_at': _formatLocalDateTime(DateTime.now()),
    }..removeWhere((key, value) => value == null);

    try {
      final hasToken = (AppSessionService.token ?? '').trim().isNotEmpty;
      final useSystemKey = !hasToken && AppConfig.hasSystemActivityKey;
      final uri = Uri.parse(useSystemKey ? _systemLogUrl : _userLogUrl);

      final headers = useSystemKey
          ? <String, String>{
              'Content-Type': 'application/json',
              'X-System-Key': AppConfig.systemActivityKey,
              if ((deviceId ?? '').trim().isNotEmpty) 'X-Device-Id': deviceId!.trim(),
            }
          : AppSessionService.buildAuthHeaders();

      if (!hasToken && !useSystemKey) {
        debugPrint('Activity log skipped: token kosong dan system key belum diset.');
        return;
      }

      final response = await http
          .post(
            uri,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 6));

      if (response.statusCode >= 400) {
        debugPrint('Activity log failed: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      debugPrint('Activity log error: $e');
    }
  }
}
