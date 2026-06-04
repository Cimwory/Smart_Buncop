import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'app_session_service.dart';

class MongoHistoryService {
  static const Map<String, MongoRangeOption> rangeOptions = {
    '5m': MongoRangeOption(label: '5 Menit', range: '-5m', window: '10s', minutes: 5),
    '10m': MongoRangeOption(label: '10 Menit', range: '-10m', window: '10s', minutes: 10),
    '15m': MongoRangeOption(label: '15 Menit', range: '-15m', window: '30s', minutes: 15),
    '20m': MongoRangeOption(label: '20 Menit', range: '-20m', window: '30s', minutes: 20),
    '30m': MongoRangeOption(label: '30 Menit', range: '-30m', window: '30s', minutes: 30),
  };

  static Future<List<Map<String, dynamic>>> fetchRows({
    required String deviceId,
    required String measurement,
    required List<String> fields,
    required String rangeKey,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final apiV1Base = AppConfig.normalizeApiV1Base();
    var token = (AppSessionService.token ?? '').trim();
    if (token.isEmpty) {
      await AppSessionService.restoreSession();
      token = (AppSessionService.token ?? '').trim();
    }
    if (apiV1Base.isEmpty) {
      throw const MongoHistoryException(
        'API base belum dikonfigurasi untuk membaca histori MongoDB.',
      );
    }
    if (token.isEmpty) {
      throw const MongoHistoryException(
        'Sesi login aplikasi tidak tersedia untuk membaca histori MongoDB.',
      );
    }

    final option = rangeOptions[rangeKey] ?? rangeOptions['15m']!;
    final uri = Uri.parse('$apiV1Base/incubator/sync/sensor-history');
    final query = <String, String>{
      'device_id': deviceId,
      'measurement': measurement,
      'range': option.range,
      'window': option.window,
      'driver': 'mongodb',
      '_ts': DateTime.now().millisecondsSinceEpoch.toString(),
    };
    if (fields.isNotEmpty) {
      query['fields'] = fields.join(',');
    }

    final rows = await _request(
      uri.replace(queryParameters: query),
      timeout: timeout,
    );
    if (rows.isNotEmpty || fields.isEmpty) {
      return rows;
    }

    query.remove('fields');
    return _request(
      uri.replace(queryParameters: query),
      timeout: timeout,
    );
  }

  static Future<List<Map<String, dynamic>>> _request(
    Uri uri, {
    required Duration timeout,
  }) async {
    final headers = <String, String>{
      ...AppSessionService.buildAuthHeaders(json: false),
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest',
    };

    final response = await http.get(
      uri,
      headers: headers,
    ).timeout(timeout);

    if (response.statusCode >= 400) {
      String message = 'HTTP ${response.statusCode}';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final rawMessage = decoded['message'] ?? decoded['error'];
          final parsedMessage = rawMessage?.toString().trim() ?? '';
          if (parsedMessage.isNotEmpty) {
            message = parsedMessage;
          }
        }
      } catch (_) {
        // Fall back to generic HTTP status text.
      }

      if (response.statusCode == 401) {
        throw MongoHistoryException(
          '$message Silakan login ulang agar chart MongoDB bisa dimuat.',
        );
      }
      throw MongoHistoryException(message);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const MongoHistoryException('Payload histori MongoDB tidak valid.');
    }

    final rawData = decoded['data'];
    if (rawData is! List) {
      return const <Map<String, dynamic>>[];
    }

    return rawData
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
}

class MongoRangeOption {
  final String label;
  final String range;
  final String window;
  final int minutes;

  const MongoRangeOption({
    required this.label,
    required this.range,
    required this.window,
    required this.minutes,
  });
}

class MongoHistoryException implements Exception {
  final String message;

  const MongoHistoryException(this.message);

  @override
  String toString() => message;
}
