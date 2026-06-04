class AppConfig {
  static const String apiBase = String.fromEnvironment(
    'BUNCOP_API_BASE',
    defaultValue: 'http://10.14.41.20:8003/api/v1',
  );

  static const String syncBase = String.fromEnvironment(
    'BUNCOP_SYNC_BASE',
    defaultValue: 'http://10.14.41.20:8003',
  );

  // ── MQTT Configuration ──
  static const String mqttHost = String.fromEnvironment(
    'BUNCOP_MQTT_HOST',
    defaultValue: '10.14.41.20',
  );

  static const int mqttPort = int.fromEnvironment(
    'BUNCOP_MQTT_PORT',
    defaultValue: 1773,
  );

  static const int mqttWsPort = int.fromEnvironment(
    'BUNCOP_MQTT_WS_PORT',
    defaultValue: 7073,
  );

  static const String mqttUsername = String.fromEnvironment(
    'BUNCOP_MQTT_USERNAME',
    defaultValue: 'buncop_app_ctrl',
  );

  static const String mqttPassword = String.fromEnvironment(
    'BUNCOP_MQTT_PASSWORD',
    defaultValue: 'Kinds123',
  );

  static const bool mqttUseTls = bool.fromEnvironment(
    'BUNCOP_MQTT_USE_TLS',
    defaultValue: false,
  );

  static const String mqttTopicPrefix = String.fromEnvironment(
    'BUNCOP_MQTT_TOPIC_PREFIX',
    defaultValue: 'buncop',
  );

  static const String inkubatorDeviceId = String.fromEnvironment(
    'BUNCOP_DEVICE_INKUBATOR',
    defaultValue: 'inkubator_1',
  );

  static const String nutrimixDeviceId = String.fromEnvironment(
    'BUNCOP_DEVICE_NUTRIMIX',
    defaultValue: 'nutrimix_1',
  );

  static const String defaultBootDeviceId = String.fromEnvironment(
    'BUNCOP_BOOT_DEVICE_ID',
    defaultValue: 'inkubator_1',
  );

  static const String notifyDeviceId = String.fromEnvironment(
    'BUNCOP_NOTIFY_DEVICE_ID',
    defaultValue: '',
  );

  static const String notifyTopic = String.fromEnvironment(
    'BUNCOP_NOTIFY_TOPIC',
    defaultValue: '',
  );

  static const String systemActivityKey = String.fromEnvironment(
    'BUNCOP_SYSTEM_ACTIVITY_KEY',
    defaultValue: '9f2a7d1c4b8e6f03d5a1c9e7b2f4a6d8e3c1b5f7a9d2c4e6f8b0a3d5c7e9f1a',
  );

  static String requireApiBase() {
    if (apiBase.isNotEmpty) {
      return apiBase;
    }
    throw StateError(
      'BUNCOP_API_BASE belum dikonfigurasi. Jalankan app dengan --dart-define=BUNCOP_API_BASE=<URL_API>',
    );
  }

  static String normalizeApiV1Base([String? raw]) {
    final base = (raw ?? apiBase).trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return '';
    if (RegExp(r'/api/v\d+$').hasMatch(base)) {
      return base;
    }
    return '$base/api/v1';
  }

  static bool get hasSystemActivityKey => systemActivityKey.trim().isNotEmpty;

  static bool get hasMqttConfig => mqttHost.trim().isNotEmpty;

  /// Debug: print all active config values at startup.
  static void printDiag() {
    final lines = [
      '┌── AppConfig Diagnostics ──',
      '│ apiBase        : ${apiBase.isEmpty ? "(empty)" : apiBase}',
      '│ mqttHost       : ${mqttHost.isEmpty ? "(empty)" : mqttHost}',
      '│ mqttPort       : $mqttPort',
      '│ mqttUsername   : ${mqttUsername.isEmpty ? "(empty)" : mqttUsername}',
      '│ mqttPassword   : ${mqttPassword.isEmpty ? "(empty)" : "***"}',
      '│ mqttTopicPrefix: ${mqttTopicPrefix.isEmpty ? "(empty)" : mqttTopicPrefix}',
      '│ notifyTopic    : ${notifyTopic.isEmpty ? "(empty)" : notifyTopic}',
      '│ hasMqttConfig  : $hasMqttConfig',
      '│ inkubatorId    : ${inkubatorDeviceId.isEmpty ? "(empty)" : inkubatorDeviceId}',
      '│ nutrimixId     : ${nutrimixDeviceId.isEmpty ? "(empty)" : nutrimixDeviceId}',
      '│ bootDeviceId   : ${defaultBootDeviceId.isEmpty ? "(empty)" : defaultBootDeviceId}',
      '└──────────────────────────',
    ];
    for (final l in lines) {
      // ignore: avoid_print
      print(l);
    }
  }
}
