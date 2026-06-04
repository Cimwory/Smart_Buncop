import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../firebase_options.dart';
import 'app_session_service.dart';
import 'auth_api_service.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (_) {
      // Firebase config may be absent in local/dev builds.
    }
  }

  debugPrint('FCM background message: ${message.messageId}');
}

class PushNotificationService {
  static bool _initialized = false;
  static bool _firebaseReady = false;
  static String? _lastSyncedToken;
  static Set<String> _lastSyncedTopics = const <String>{};

  static bool get _isSupportedMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> init() async {
    if (_initialized || !_isSupportedMobile) {
      return;
    }

    _initialized = true;

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    try {
      await Firebase.initializeApp();
      _firebaseReady = true;
    } catch (e) {
      debugPrint('FCM auto-init failed, retry with explicit options ($e)');
      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
        _firebaseReady = true;
      } catch (innerError) {
        debugPrint('FCM init skipped: Firebase not configured yet ($innerError)');
        return;
      }
    }

    try {
      final messaging = FirebaseMessaging.instance;

      await messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      await messaging.setAutoInitEnabled(true);

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      for (final currentTopic in _buildTopics()) {
        await messaging.subscribeToTopic(currentTopic);
        debugPrint('FCM subscribed topic: $currentTopic');
      }

      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        debugPrint('FCM token: $token');
        await _syncTokenIfPossible(token);
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        debugPrint('FCM token refreshed: $newToken');
        _lastSyncedToken = null;
        await _syncTokenIfPossible(newToken);
      });

      FirebaseMessaging.onMessage.listen((message) async {
        final title = message.notification?.title ??
            message.data['title']?.toString() ??
            'VitaRoot Notification';
        final body = message.notification?.body ??
            message.data['body']?.toString() ??
            message.data['message']?.toString() ??
            '';

        if (body.isNotEmpty) {
          await NotificationService.show(title, body);
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        debugPrint('FCM opened app: ${message.messageId}');
      });

      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('FCM initial message: ${initialMessage.messageId}');
      }
    } catch (e) {
      debugPrint('FCM runtime setup warning: $e');
    }
  }

  static Future<bool> isReady() async {
    return _firebaseReady;
  }

  static Future<void> onSessionAvailable() async {
    if (!_firebaseReady) {
      return;
    }

    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      return;
    }

    await _syncTokenIfPossible(token);
  }

  static Future<void> unregisterCurrentToken() async {
    if (!_firebaseReady || !_isSupportedMobile) {
      return;
    }

    final sessionToken = AppSessionService.token ?? '';
    if (sessionToken.isEmpty) {
      return;
    }

    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      return;
    }

    try {
      await AuthApiService().unregisterNotificationToken(token: token);
      _lastSyncedToken = null;
      _lastSyncedTopics = const <String>{};
    } catch (e) {
      debugPrint('FCM unregister warning: $e');
    }
  }

  static Future<void> _syncTokenIfPossible(String token) async {
    final sessionToken = AppSessionService.token ?? '';
    if (sessionToken.isEmpty) {
      return;
    }

    final topics = _buildTopics().toSet();
    final shouldSync = _lastSyncedToken != token || !setEquals(_lastSyncedTopics, topics);
    if (!shouldSync) {
      return;
    }

    try {
      await AuthApiService().registerNotificationToken(
        token: token,
        platform: Platform.isIOS ? 'ios' : 'android',
        topics: topics.toList(),
        deviceName: Platform.operatingSystem,
        deviceModel: Platform.operatingSystemVersion,
      );
      _lastSyncedToken = token;
      _lastSyncedTopics = topics;
      debugPrint('FCM token synced to backend.');
    } catch (e) {
      debugPrint('FCM token sync warning: $e');
    }
  }

  static List<String> _buildTopics() {
    final topics = <String>{};

    final generalTopic = AppConfig.notifyTopic.trim();
    if (generalTopic.isNotEmpty) {
      topics.add(generalTopic);
    }

    topics.add('incubator_alerts');
    topics.add('indoor_farming_alerts');

    final incubatorDeviceTopic = _deviceTopic(
      AppConfig.inkubatorDeviceId.isNotEmpty
          ? AppConfig.inkubatorDeviceId
          : AppConfig.notifyDeviceId,
    );
    if (incubatorDeviceTopic != null) {
      topics.add(incubatorDeviceTopic);
    }

    final nutrimixDeviceTopic = _deviceTopic(AppConfig.nutrimixDeviceId);
    if (nutrimixDeviceTopic != null) {
      topics.add('nutrimix_alerts');
      topics.add(nutrimixDeviceTopic);
    }

    topics.add('device_indoor_farming_sensor_alerts');

    return topics.toList(growable: false);
  }

  static String? _deviceTopic(String deviceId) {
    final value = deviceId.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
    if (value.isEmpty) {
      return null;
    }

    return 'device_${value.replaceAll(RegExp(r'^_+|_+$'), '')}_alerts';
  }
}
