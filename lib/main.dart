import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'pages/splash_screen.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/mqtt_service.dart';


/// GLOBAL THEME CONTROLLER
final ValueNotifier<ThemeMode> themeNotifier =
    ValueNotifier(ThemeMode.dark);


Future<void> main() async {

  WidgetsFlutterBinding.ensureInitialized();

  /// PRINT CONFIG FOR DEBUGGING
  AppConfig.printDiag();

  /// INIT MQTT (primary transport for IoT data)
  if (AppConfig.hasMqttConfig) {
    try {
      final ok = await MqttService.instance.connect();
      debugPrint("MQTT connect result: $ok (host=${AppConfig.mqttHost})");
    } catch (e) {
      debugPrint("MQTT init warning: $e");
    }
  } else {
    debugPrint('MQTT skipped: hasMqttConfig=false (host=${AppConfig.mqttHost})');
  }

  /// INIT LOCAL NOTIFICATION
  try {
    await NotificationService.init();
  } catch (e) {
    debugPrint("Notification init warning: $e");
  }

  /// Optional: realtime MQTT-based local notifications (alerts/status thresholds)
  /// Enabled only when `BUNCOP_NOTIFY_DEVICE_ID` and MQTT config are provided.
  try {
    if (AppConfig.hasMqttConfig) {
      NotificationService.startRealtimeListener();
    }
  } catch (e) {
    debugPrint("Realtime notification listener warning: $e");
  }

  /// INIT FCM PUSH NOTIFICATION
  try {
    await PushNotificationService.init();
  } catch (e) {
    debugPrint("FCM init warning: $e");
  }

  runApp(const MyApp());
}



class MyApp extends StatelessWidget {

  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {

    return ValueListenableBuilder<ThemeMode>(

      valueListenable: themeNotifier,

      builder: (context, mode, _) {

        return MaterialApp(

          debugShowCheckedModeBanner: false,

          title: "VitaRoot",

          themeMode: mode,

          /// LIGHT THEME
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2E7D32),
              brightness: Brightness.light,
            ),
          ),

          /// DARK THEME (recommended for industrial look)
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2E7D32),
              brightness: Brightness.dark,
            ),
          ),

          /// SPLASH SCREEN FIRST
          home: SplashScreen(
            deviceId: AppConfig.defaultBootDeviceId.isNotEmpty
                ? AppConfig.defaultBootDeviceId
                : AppConfig.inkubatorDeviceId,
          ),

        );

      },

    );

  }

}
