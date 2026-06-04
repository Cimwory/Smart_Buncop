/// Transport-agnostic device repository interface.
/// Implementations use MQTT as the transport layer.
abstract class DeviceRepository {
  String get deviceId;

  Stream<String> modeStream();
  Future<void> setMode(bool auto);
  Future<String> getMode();

  Stream<bool> relayValueStream(String key);
  Future<void> setRelay(String key, bool value);

  Stream<double?> temperatureStream();
  Stream<double?> humidityStream();
  Stream<double?> soilMoistureStream();
  Stream<int?> lampPwmStream();
  Future<void> setLampPWM(int percent);

  Stream<bool> espOnlineStream();

  Stream<String> activePlantStream();
  Future<void> setActivePlant(String id);

  Stream<int?> sprayerDurationStream();
  Future<void> setManualSprayerDuration(int seconds);

  Stream<Map<String, String>> manualSprayerTimesStream();
  Future<void> setManualSprayerTimes(Map<String, String> times);

  Future<void> dispose();
}
