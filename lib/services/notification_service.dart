import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../config/app_config.dart';
import 'mqtt_service.dart';


class NotificationService {

  static final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();

  static bool get _isWeb => kIsWeb;
  static bool get _isAndroid => !_isWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _isIOS => !_isWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static String get _defaultNotifyDeviceId => AppConfig.notifyDeviceId;

  // ================= INIT =================

  static Future init() async {
  if (_isWeb) {
    debugPrint("Notification init skipped on web");
    return;
  }

  const android =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const settings =
      InitializationSettings(android: android);

  await _notif.initialize(settings);

  /// WAJIB TAMBAH INI
  const AndroidNotificationChannel channel =
      AndroidNotificationChannel(
    'esp_channel',
    'VitaRoot Notifications',
    importance: Importance.max,
  );

  await _notif
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await requestPermission();
}

  // ================= REQUEST PERMISSION =================

  static Future requestPermission() async {
    // FCM permission is only relevant on mobile targets.
    if (!_isAndroid && !_isIOS) {
      return;
    }

    /// LOCAL NOTIF PERMISSION
    if (_isAndroid) {

      final androidPlugin =
          _notif.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      await androidPlugin?.requestNotificationsPermission();

    }

  }

  static void startRealtimeListener({String? deviceId}) {
  final targetDeviceId = (deviceId ?? _defaultNotifyDeviceId).trim();
  if (targetDeviceId.isEmpty) {
    debugPrint("Realtime listener skipped: notify device id kosong");
    return;
  }

  if (!AppConfig.hasMqttConfig) {
    debugPrint("Realtime listener skipped: MQTT not configured");
    return;
  }

  final mqtt = MqttService.instance;
  final prefix = AppConfig.mqttTopicPrefix;

  // Subscribe to alert topics for this device (all areas)
  mqtt.subscribeJson('$prefix/+/$targetDeviceId/alert').listen((data) {
    final alertType = data['type']?.toString() ?? 'alert';
    final message = data['message']?.toString() ?? '';

    switch (alertType) {
      case 'high_temperature':
        show("Peringatan suhu tinggi", message.isNotEmpty ? message : "Suhu melebihi batas");
        break;
      case 'low_humidity':
        show("Kelembapan rendah", message.isNotEmpty ? message : "Kelembapan di bawah batas");
        break;
      case 'device_offline':
        show("ESP Offline", message.isNotEmpty ? message : "Device tidak terhubung");
        break;
      default:
        show("VitaRoot Alert", message.isNotEmpty ? message : alertType);
    }
  });

  // Subscribe to status topic for sprayer notifications
  mqtt.subscribeJson('$prefix/+/$targetDeviceId/status').listen((data) {
    if (data.containsKey('relay') && data['relay'] is Map) {
      final relays = data['relay'] as Map;
      if (relays['sprayer'] == true) {
        show("VitaRoot", "Sprayer sedang aktif");
      }
    }
  });

  // Subscribe to telemetry for threshold alerts
  mqtt.subscribeJson('$prefix/+/$targetDeviceId/telemetry').listen((data) {
    if (data.containsKey('temperature')) {
      final temp = (data['temperature'] as num?)?.toDouble();
      if (temp != null && temp > 35) {
        show("Peringatan suhu tinggi", "Suhu ${temp.toStringAsFixed(1)}°C");
      }
    }
    if (data.containsKey('humidity')) {
      final hum = (data['humidity'] as num?)?.toDouble();
      if (hum != null && hum < 40) {
        show("Kelembapan rendah", "Humidity ${hum.toStringAsFixed(1)}%");
      }
    }
  });
}

  // ================= SHOW LOCAL =================

  static Future show(
      String title,
      String body,
      ) async {

    const androidDetails =
        AndroidNotificationDetails(
      'esp_channel',
      'ESP Inkubator',
      importance: Importance.max,
      priority: Priority.high,
    );

    const details =
        NotificationDetails(android: androidDetails);

    await _notif.show(
      DateTime.now().microsecondsSinceEpoch % 0x7FFFFFFF,
      title,
      body,
      details,
    );

  }

}
