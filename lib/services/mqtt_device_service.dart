import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../domain/repositories/device_repository.dart';
import '../domain/repositories/plant_repository.dart';
import 'app_session_service.dart';
import 'mqtt_service.dart';

/// MQTT-based implementation of [DeviceRepository] and [PlantRepository].
///
/// Topic naming: buncop/{area}/{deviceId}/{suffix}
///   telemetry — ESP publishes sensor data (temperature, humidity, weight, etc.)
///   status    — ESP publishes full device state (mode, relays, lamp_pwm, etc.)
///   command   — App publishes control commands to ESP
///   ack       — ESP publishes acknowledgments for commands
///   alert     — ESP publishes threshold/error alerts
class MqttDeviceService implements DeviceRepository, PlantRepository {
  static const int _telemetryHistoryLimit = 240;
  static const String _prefsStatePrefix = 'mqtt_device_state_v1_';
  static final Map<String, List<Map<String, dynamic>>> _telemetryHistory = {};
  static final Map<String, Map<String, dynamic>> _latestByNode = {};

  @override
  final String deviceId;

  final String area;
  final MqttService _mqtt;

  // ── Cached state from last status message ──
  final _state = <String, dynamic>{};
  double? _latestTemperature;
  double? _latestHumidity;
  double? _latestSoilMoisture;

  String get _nodeKey => '$area/$deviceId';

  // ── Stream controllers for individual fields ──
  final _modeCtrl = StreamController<String>.broadcast();
  final _tempCtrl = StreamController<double?>.broadcast();
  final _humCtrl = StreamController<double?>.broadcast();
  final _soilCtrl = StreamController<double?>.broadcast();
  final _lampPwmCtrl = StreamController<int?>.broadcast();
  final _activePlantCtrl = StreamController<String>.broadcast();
  final _sprayerDurCtrl = StreamController<int?>.broadcast();
  final _sprayerTimesCtrl = StreamController<Map<String, String>>.broadcast();
  final _relayCtrl = <String, StreamController<bool>>{};
  final _onlineCtrl = StreamController<bool>.broadcast();
  final _plantsCtrl = StreamController<Map<String, dynamic>>.broadcast();

  // ── Online detection ──
  int _lastSeenEpoch = 0;
  bool _lastOnlineState = false;
  Timer? _onlineCheckTimer;

  // ── Plants cache (from API) ──
  Map<String, dynamic> _plantsCache = {};
  Timer? _plantsRefreshTimer;
  Timer? _autoPlantSyncTimer;
  Timer? _runtimeSnapshotTimer;
  Timer? _cachePersistTimer;
  String _lastAutoSyncSignature = '';
  int _lastAutoRepairEpochMs = 0;
  String _lastAutoRepairSignature = '';

  StreamSubscription? _telemetrySub;
  StreamSubscription? _statusSub;
  StreamSubscription? _alertSub;

  MqttDeviceService({
    required this.deviceId,
    this.area = 'incubator',
    MqttService? mqtt,
  }) : _mqtt = mqtt ?? MqttService.instance {
    _init();
  }

  String _topic(String suffix) => _mqtt.topic(area, deviceId, suffix);
  String get _prefsCacheKey => '$_prefsStatePrefix$_nodeKey';

  String get cachedMode => _state['mode']?.toString() ?? 'manual';
  String get cachedActivePlantId => _state['active_plant']?.toString() ?? '';
  double? get cachedTemperature => _latestTemperature;
  double? get cachedHumidity => _latestHumidity;
  double? get cachedSoilMoisture => _latestSoilMoisture;
  bool cachedRelayValue(String key) {
    if (_state['relay'] is! Map) return false;
    final relays = Map<String, dynamic>.from(_state['relay'] as Map);
    return relays[key] == true;
  }

  bool get _hasCachedControlState {
    final mode = _state['mode']?.toString();
    final hasRelay = _state['relay'] is Map &&
        Map<String, dynamic>.from(_state['relay'] as Map).isNotEmpty;
    final activePlant = _state['active_plant']?.toString() ?? '';
    return (mode != null && mode.isNotEmpty) || hasRelay || activePlant.isNotEmpty;
  }

  void _init() {
    _seedStateFromCache();
    _seedLatestSensorFromHistory();
    unawaited(() async {
      await _restorePersistedState();
      await _refreshRuntimeSnapshot();
    }());

    // Subscribe to telemetry messages (sensor data)
    _telemetrySub = _mqtt
        .subscribeJson(_topic('telemetry'))
        .listen(_onTelemetry);

    // Subscribe to status messages (full device state, retained)
    _statusSub = _mqtt
        .subscribeJson(_topic('status'))
        .listen(_onStatus);

    // Subscribe to alerts
    _alertSub = _mqtt
        .subscribeJson(_topic('alert'))
        .listen(_onAlert);

    // Online check timer (similar to heartbeat approach)
    _onlineCheckTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _evaluateOnline(),
    );

    // Seed UI state from backend snapshot so values still appear before
    // the next live telemetry packet arrives.
    _runtimeSnapshotTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refreshRuntimeSnapshot(),
    );

    // Load plants from API initially and refresh periodically
    _refreshPlants();
    _plantsRefreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshPlants(),
    );
    _autoPlantSyncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _syncActivePlantFromApi(),
    );
  }

  void _seedStateFromCache() {
    final cached = _latestByNode[_nodeKey];
    if (cached == null || cached.isEmpty) return;
    _state.addAll(cached);

    final temp = cached['temperature'];
    final hum = cached['humidity'];
    final soil = cached['soil_moisture'];
    if (temp is num) _latestTemperature = temp.toDouble();
    if (hum is num) _latestHumidity = hum.toDouble();
    if (soil is num) _latestSoilMoisture = soil.toDouble();

    final mode = cached['mode']?.toString();
    if (mode != null && mode.isNotEmpty) {
      _modeCtrl.add(mode);
    }

    final lampPwm = cached['lamp_pwm'];
    if (lampPwm is num) {
      _lampPwmCtrl.add(lampPwm.toInt());
    }

    final activePlant = cached['active_plant']?.toString();
    if (activePlant != null) {
      _activePlantCtrl.add(activePlant);
    }

    final sprayerDuration = cached['sprayer_duration'];
    if (sprayerDuration is num) {
      _sprayerDurCtrl.add(sprayerDuration.toInt());
    }

    final sprayerTimes = cached['sprayer_times'];
    if (sprayerTimes is Map) {
      _sprayerTimesCtrl.add(
        Map<String, String>.from(
          sprayerTimes.map((key, value) => MapEntry('$key', '$value')),
        ),
      );
    }

    final relays = cached['relay'];
    if (relays is Map) {
      for (final entry in relays.entries) {
        _getRelayCtrl('${entry.key}').add(entry.value == true);
      }
    }

    final lastSeen = (cached['last_seen'] as num?)?.toInt() ?? 0;
    if (lastSeen > 0) {
      _lastSeenEpoch = lastSeen;
    }

    if (cached['online'] is bool) {
      _lastOnlineState = cached['online'] == true;
      _onlineCtrl.add(_lastOnlineState);
    }
  }

  void _seedLatestSensorFromHistory() {
    final history = _telemetryHistory[deviceId];
    if (history == null || history.isEmpty) return;
    final latest = history.last;
    final temp = latest['temperature'];
    final hum = latest['humidity'];
    final soil = latest['soil_moisture'];
    if (temp is num) {
      _latestTemperature = temp.toDouble();
    }
    if (hum is num) {
      _latestHumidity = hum.toDouble();
    }
    if (soil is num) {
      _latestSoilMoisture = soil.toDouble();
    }
  }

  // ── Telemetry handler (sensor data from ESP) ──
  void _onTelemetry(Map<String, dynamic> data) {
    debugPrint('[MQTT] Telemetry from $deviceId: $data');
    if (data.containsKey('temperature')) {
      final temp = (data['temperature'] as num?)?.toDouble();
      _pushTemperature(temp);
    }
    if (data.containsKey('humidity')) {
      final hum = (data['humidity'] as num?)?.toDouble();
      _pushHumidity(hum);
    }
    if (data.containsKey('soil_moisture')) {
      final soil = (data['soil_moisture'] as num?)?.toDouble();
      _pushSoilMoisture(soil);
    }
    // Update last_seen from telemetry timestamp
    final ts = data['timestamp'] as int? ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _lastSeenEpoch = ts;
    _rememberTelemetry(
      deviceId,
      temperature: (data['temperature'] as num?)?.toDouble(),
      humidity: (data['humidity'] as num?)?.toDouble(),
      soilMoisture: (data['soil_moisture'] as num?)?.toDouble(),
      timestamp: ts,
    );
    _evaluateOnline();
  }

  static List<Map<String, dynamic>> telemetryHistoryFor(String deviceId) {
    final history = _telemetryHistory[deviceId];
    if (history == null) return const <Map<String, dynamic>>[];
    return List<Map<String, dynamic>>.unmodifiable(history);
  }

  static void _rememberTelemetry(
    String deviceId, {
    required double? temperature,
    required double? humidity,
    required double? soilMoisture,
    required int timestamp,
  }) {
    if (temperature == null && humidity == null && soilMoisture == null) return;
    final history = _telemetryHistory.putIfAbsent(
      deviceId,
      () => <Map<String, dynamic>>[],
    );
    history.add(<String, dynamic>{
      'time': DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: false)
          .toIso8601String(),
      'temperature': temperature,
      'humidity': humidity,
      'soil_moisture': soilMoisture,
    });
    if (history.length > _telemetryHistoryLimit) {
      history.removeRange(0, history.length - _telemetryHistoryLimit);
    }
  }

  // ── Status handler (full device state from ESP, retained) ──
  void _onStatus(Map<String, dynamic> data) {
    debugPrint('[MQTT] ★ Status from $deviceId: $data');
    _state.addAll(data);

    _emitTemperatureValue(data['temperature']);
    _emitHumidityValue(data['humidity']);
    _emitSoilMoistureValue(data['soil_moisture']);
    if (data['sensor'] is Map) {
      final sensor = Map<String, dynamic>.from(data['sensor'] as Map);
      _emitTemperatureValue(sensor['temperature']);
      _emitHumidityValue(sensor['humidity']);
      _emitSoilMoistureValue(sensor['soil_moisture']);
    }

    if (data.containsKey('mode')) {
      final mode = data['mode']?.toString() ?? 'manual';
      _rememberState('mode', mode);
      _modeCtrl.add(mode);
    }

    if (data.containsKey('relay') && data['relay'] is Map) {
      final relays = Map<String, dynamic>.from(data['relay'] as Map);
      _rememberState('relay', Map<String, dynamic>.from(relays));
      for (final entry in relays.entries) {
        _getRelayCtrl(entry.key).add(entry.value == true);
      }
    }

    if (data.containsKey('lamp_pwm')) {
      final lampPwm = (data['lamp_pwm'] as num?)?.toInt();
      _rememberState('lamp_pwm', lampPwm);
      _lampPwmCtrl.add(lampPwm);
    }

    if (data.containsKey('active_plant')) {
      final activePlant = data['active_plant']?.toString() ?? '';
      _rememberState('active_plant', activePlant);
      _activePlantCtrl.add(activePlant);
    }

    if (data.containsKey('last_seen')) {
      _lastSeenEpoch = (data['last_seen'] as num?)?.toInt() ?? 0;
      _rememberState('last_seen', _lastSeenEpoch);
      _evaluateOnline();
    }

    // Sprayer data — ESP publishes at top level (sprayer_duration, sprayer_times)
    if (data.containsKey('sprayer_duration')) {
      final duration = (data['sprayer_duration'] as num?)?.toInt();
      _rememberState('sprayer_duration', duration);
      _sprayerDurCtrl.add(duration);
    }
    if (data.containsKey('sprayer_times') && data['sprayer_times'] is List) {
      final list = data['sprayer_times'] as List;
      final times = <String, String>{};
      for (var i = 0; i < list.length; i++) {
        times[i.toString()] = list[i].toString();
      }
      _rememberState('sprayer_times', Map<String, String>.from(times));
      _sprayerTimesCtrl.add(times);
    }

    // Also support legacy nested format (manual.sprayer_duration)
    if (data.containsKey('manual') && data['manual'] is Map) {
      final manual = Map<String, dynamic>.from(data['manual'] as Map);
      if (manual.containsKey('sprayer_duration')) {
        final duration = (manual['sprayer_duration'] as num?)?.toInt();
        _rememberState('sprayer_duration', duration);
        _sprayerDurCtrl.add(duration);
      }
      if (manual.containsKey('sprayer_times') && manual['sprayer_times'] is Map) {
        final times = Map<String, String>.from(
          (manual['sprayer_times'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ),
        );
        _rememberState('sprayer_times', Map<String, String>.from(times));
        _sprayerTimesCtrl.add(times);
      }
    }

    unawaited(_syncActivePlantFromApi());
  }

  void _onAlert(Map<String, dynamic> data) {
    debugPrint('[MQTT] Alert from $deviceId: $data');
  }

  void _evaluateOnline() {
    const thresholdSec = 45; // 3x heartbeat (15s)
    if (_lastSeenEpoch <= 0) {
      if (_lastOnlineState) {
        _lastOnlineState = false;
        _rememberState('online', false);
        _onlineCtrl.add(false);
        debugPrint('[MQTT] Online → OFFLINE (no last_seen)');
      }
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final online = (now - _lastSeenEpoch) <= thresholdSec;
    if (online != _lastOnlineState) {
      _lastOnlineState = online;
      _rememberState('online', online);
      _onlineCtrl.add(online);
      debugPrint('[MQTT] Online → ${online ? "ONLINE" : "OFFLINE"} (lastSeen=$_lastSeenEpoch, now=$now, diff=${now - _lastSeenEpoch})');
    }
  }

  void _rememberState(String key, dynamic value) {
    final cache = _latestByNode.putIfAbsent(_nodeKey, () => <String, dynamic>{});
    if (value == null) {
      cache.remove(key);
      _schedulePersistedStateWrite();
      return;
    }
    if (value is Map) {
      cache[key] = Map<String, dynamic>.from(value);
      _schedulePersistedStateWrite();
      return;
    }
    if (value is List) {
      cache[key] = List<dynamic>.from(value);
      _schedulePersistedStateWrite();
      return;
    }
    cache[key] = value;
    _schedulePersistedStateWrite();
  }

  void _schedulePersistedStateWrite() {
    _cachePersistTimer?.cancel();
    _cachePersistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistStateToPrefs());
    });
  }

  Future<void> _persistStateToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cache = Map<String, dynamic>.from(_latestByNode[_nodeKey] ?? _state);
      if (_latestTemperature != null) {
        cache['temperature'] = _latestTemperature;
      }
      if (_latestHumidity != null) {
        cache['humidity'] = _latestHumidity;
      }
      if (_latestSoilMoisture != null) {
        cache['soil_moisture'] = _latestSoilMoisture;
      }
      await prefs.setString(_prefsCacheKey, jsonEncode(cache));
    } catch (e) {
      debugPrint('[MQTT] Persist state cache error: $e');
    }
  }

  Future<void> _restorePersistedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final cached = Map<String, dynamic>.from(decoded);
      if (cached.isEmpty) return;

      final target =
          _latestByNode.putIfAbsent(_nodeKey, () => <String, dynamic>{});
      target.addAll(cached);
      _seedStateFromCache();
    } catch (e) {
      debugPrint('[MQTT] Restore state cache error: $e');
    }
  }

  Stream<T> _replayStream<T>(Stream<T> source, T? current) => Stream<T>.multi(
        (controller) {
          if (current != null) {
            controller.add(current);
          }
          final sub = source.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.onCancel = sub.cancel;
        },
        isBroadcast: true,
      );

  StreamController<bool> _getRelayCtrl(String key) {
    return _relayCtrl.putIfAbsent(
        key, () => StreamController<bool>.broadcast());
  }

  // ── Command publishing ──
  Future<bool> _sendCommand(String type, dynamic value,
      {Map<String, dynamic>? extra}) async {
    final payload = <String, dynamic>{
      'type': type,
      'value': value,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (extra != null) payload.addAll(extra);
    if (!_mqtt.isConnected) {
      debugPrint('[MQTT] Command $type requested while disconnected, reconnecting...');
      final connected = await _mqtt.connect();
      if (!connected) {
        debugPrint('[MQTT] Command $type aborted: reconnect failed');
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (!_mqtt.isConnected) {
      debugPrint('[MQTT] Command $type aborted: MQTT still disconnected');
      return false;
    }

    _mqtt.publishJson(_topic('command'), payload);
    return true;
  }

  // ═══════════════════════ DeviceRepository ═══════════════════════

  @override
  Stream<String> modeStream() =>
      _replayStream<String>(_modeCtrl.stream, _state['mode']?.toString());

  @override
  Future<void> setMode(bool auto) async {
    final mode = auto ? 'auto' : 'manual';
    // Optimistic update
    _state['mode'] = mode;
    _rememberState('mode', mode);
    _modeCtrl.add(mode);
    await _sendCommand('set_mode', mode);
    _syncActivity(
      action: 'mobile.inkubator.mode.change',
      description: 'Mode inkubator diubah',
      metadata: {'mode': mode},
    );
  }

  @override
  Future<String> getMode() async => _state['mode']?.toString() ?? 'manual';

  @override
  Stream<bool> relayValueStream(String key) {
    bool? current;
    if (_state['relay'] is Map) {
      final relays = Map<String, dynamic>.from(_state['relay'] as Map);
      if (relays.containsKey(key)) {
        current = relays[key] == true;
      }
    }
    return _replayStream<bool>(_getRelayCtrl(key).stream, current);
  }

  @override
  Future<void> setRelay(String key, bool value) async {
    // Optimistic update — UI updates immediately without waiting for ESP
    final relays = (_state['relay'] is Map)
        ? Map<String, dynamic>.from(_state['relay'] as Map)
        : <String, dynamic>{};
    relays[key] = value;
    _state['relay'] = relays;
    _rememberState('relay', relays);
    _getRelayCtrl(key).add(value);
    await _sendCommand('set_relay', value, extra: {'relay': key});
    _syncActivity(
      action: 'mobile.inkubator.relay.toggle',
      description: 'Relay diubah dari aplikasi mobile',
      metadata: {'relay': key, 'state': value},
    );
  }

  @override
  Stream<double?> temperatureStream() => Stream<double?>.multi(
        (controller) {
          if (_latestTemperature != null) {
            controller.add(_latestTemperature);
          }
          final sub = _tempCtrl.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.onCancel = sub.cancel;
        },
        isBroadcast: true,
      );

  @override
  Stream<double?> humidityStream() => Stream<double?>.multi(
        (controller) {
          if (_latestHumidity != null) {
            controller.add(_latestHumidity);
          }
          final sub = _humCtrl.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.onCancel = sub.cancel;
        },
        isBroadcast: true,
      );

  @override
  Stream<double?> soilMoistureStream() => Stream<double?>.multi(
        (controller) {
          if (_latestSoilMoisture != null) {
            controller.add(_latestSoilMoisture);
          }
          final sub = _soilCtrl.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.onCancel = sub.cancel;
        },
        isBroadcast: true,
      );

  @override
  Stream<int?> lampPwmStream() => _replayStream<int?>(
        _lampPwmCtrl.stream,
        (_state['lamp_pwm'] as num?)?.toInt(),
      );

  @override
  Future<void> setLampPWM(int percent) async {
    // Optimistic update
    _state['lamp_pwm'] = percent;
    _rememberState('lamp_pwm', percent);
    _lampPwmCtrl.add(percent);
    await _sendCommand('set_lamp_pwm', percent);
    _syncActivity(
      action: 'mobile.inkubator.lamp_pwm.change',
      description: 'PWM lampu diubah dari aplikasi mobile',
      metadata: {'lamp_pwm': percent},
    );
  }

  @override
  Stream<bool> espOnlineStream() =>
      _replayStream<bool>(_onlineCtrl.stream, _lastOnlineState);

  @override
  Stream<String> activePlantStream() => _replayStream<String>(
        _activePlantCtrl.stream,
        _state['active_plant']?.toString(),
      );

  @override
  Future<void> setActivePlant(String id) async {
    if (id.isEmpty) {
      // Clear active plant — ESP handles null/empty value
      _state['active_plant'] = '';
      _rememberState('active_plant', '');
      _activePlantCtrl.add('');
      await _sendCommand('set_active_plant', '');
    } else {
      // Build full plant config payload matching ESP firmware expectations
      final plant = await getPlantById(id);
      final plantConfig = _buildPlantConfigPayload(id, plant);
      await _sendCommand('set_active_plant', plantConfig);

      await _syncApplyPlant(id);
    }
    _syncActivity(
      action: 'mobile.inkubator.active_plant.change',
      description: 'Tanaman aktif diubah dari aplikasi mobile',
      metadata: {'active_plant_id': id},
    );
  }

  @override
  Stream<int?> sprayerDurationStream() => _replayStream<int?>(
        _sprayerDurCtrl.stream,
        (_state['sprayer_duration'] as num?)?.toInt(),
      );

  @override
  Future<void> setManualSprayerDuration(int seconds) async {
    _state['sprayer_duration'] = seconds;
    _rememberState('sprayer_duration', seconds);
    _sprayerDurCtrl.add(seconds);
    await _sendCommand('set_sprayer_duration', seconds);
    await _syncManualSchedule(durationOverride: seconds);
  }

  @override
  Stream<Map<String, String>> manualSprayerTimesStream() =>
      _replayStream<Map<String, String>>(
        _sprayerTimesCtrl.stream,
        _state['sprayer_times'] is Map
            ? Map<String, String>.from(
                (_state['sprayer_times'] as Map)
                    .map((k, v) => MapEntry('$k', '$v')),
              )
            : null,
      );

  @override
  Future<void> setManualSprayerTimes(Map<String, String> times) async {
    final copied = Map<String, String>.from(times);
    _state['sprayer_times'] = copied;
    _rememberState('sprayer_times', copied);
    _sprayerTimesCtrl.add(copied);
    await _sendCommand('set_sprayer_times', times);
    final orderedTimes = _orderedTimesFromMap(times);
    await _syncManualSchedule(timesOverride: orderedTimes);
  }

  // ═══════════════════════ PlantRepository ═══════════════════════

  @override
  Stream<Map<String, dynamic>> plantStream() => _replayStream<Map<String, dynamic>>(
        _plantsCtrl.stream,
        Map<String, dynamic>.from(_plantsCache),
      );

  @override
  Stream<Map<String, dynamic>?> plantTempConfig(String id) {
    return plantStream().map((plants) {
      final plant = plants[id];
      if (plant is Map && plant['temp_optimal'] is Map) {
        return Map<String, dynamic>.from(plant['temp_optimal'] as Map);
      }
      return null;
    });
  }

  @override
  Future<void> addPlant(Map<String, dynamic> data) async {
    final id = 'plant_${DateTime.now().millisecondsSinceEpoch}';
    await _postSync('/plant', {
      ...data,
      'id': id,
      'device_id': deviceId,
    });
    _syncActivity(
      action: 'mobile.inkubator.plant.add',
      description: 'Tambah tanaman dari aplikasi mobile',
      metadata: {'plant_id': id, 'name': data['name']},
    );
    await _refreshPlants();
  }

  @override
  Future<void> updatePlant(String id, Map<String, dynamic> data) async {
    await _postSync('/plant', {
      ...data,
      'id': id,
      'device_id': deviceId,
    });
    _syncActivity(
      action: 'mobile.inkubator.plant.update',
      description: 'Ubah tanaman dari aplikasi mobile',
      metadata: {'plant_id': id, 'name': data['name']},
    );
    await _refreshPlants();
    if ((_state['mode']?.toString() ?? 'manual') == 'auto' &&
        (_state['active_plant']?.toString() ?? '') == id) {
      _lastAutoSyncSignature = '';
      await _syncActivePlantFromApi();
    }
  }

  @override
  Future<void> deletePlant(String id) async {
    await _deleteSync('/plant/$id');
    _syncActivity(
      action: 'mobile.inkubator.plant.delete',
      description: 'Hapus tanaman dari aplikasi mobile',
      metadata: {'plant_id': id},
    );
    await _refreshPlants();
  }

  @override
  Future<Map<String, dynamic>?> getTempOptimal(String plantId) async {
    final plant = _plantsCache[plantId];
    if (plant is Map && plant['temp_optimal'] is Map) {
      return Map<String, dynamic>.from(plant['temp_optimal'] as Map);
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> getPlantById(String plantId) async {
    final plant = _plantsCache[plantId];
    if (plant is Map) {
      return Map<String, dynamic>.from(plant);
    }
    return null;
  }

  // ═══════════════════════ API Sync Helpers ═══════════════════════

  static String? _resolveApiBaseUrl() {
    final apiBase = AppConfig.apiBase.trim();
    if (apiBase.isEmpty) return null;
    return apiBase.replaceAll(RegExp(r'/+$'), '');
  }

  static String? _resolveRuntimeSnapshotUrl() {
    final apiBase = AppConfig.normalizeApiV1Base();
    if (apiBase.isEmpty) return null;
    return '$apiBase/incubator/runtime/snapshot';
  }

  static String? _resolveSyncBaseUrl() {
    final explicitSync = AppConfig.syncBase.trim();
    if (explicitSync.isNotEmpty) {
      final normalized = explicitSync.replaceAll(RegExp(r'/+$'), '');
      if (normalized.endsWith('/incubator/sync')) {
        return normalized;
      }
      final normalizedApiBase = AppConfig.normalizeApiV1Base(normalized);
      if (normalizedApiBase.isNotEmpty) {
        return '$normalizedApiBase/incubator/sync';
      }
      return normalized;
    }
    final apiBase = _resolveApiBaseUrl();
    if (apiBase == null) return null;
    return '$apiBase/incubator/sync';
  }

  static String? _resolveSystemActivityUrl() {
    final apiBase = _resolveApiBaseUrl();
    if (apiBase == null) return null;
    return '$apiBase/system/activity-logs';
  }

  Future<void> _refreshPlants() async {
    final syncBaseUrl = _resolveSyncBaseUrl();
    if (syncBaseUrl == null) return;
    try {
      final uri =
          Uri.parse('$syncBaseUrl/state').replace(queryParameters: {'device_id': deviceId});
      final headers = (AppSessionService.token ?? '').isNotEmpty
          ? AppSessionService.buildAuthHeaders(json: false)
          : <String, String>{};
      final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 6));
      if (response.statusCode < 400) {
        final body = jsonDecode(response.body);
        if (body is Map && body['plants'] is Map) {
          _plantsCache = Map<String, dynamic>.from(body['plants'] as Map);
          _plantsCtrl.add(_plantsCache);
          debugPrint(
            '[MQTT] Plants refresh success: device=$deviceId count=${_plantsCache.length} url=$uri',
          );
          await _syncActivePlantFromApi();
        }
      } else {
        debugPrint(
          '[MQTT] Plants refresh failed: status=${response.statusCode} url=$uri body=${response.body}',
        );
      }
    } catch (e) {
      debugPrint('[MQTT] Plants refresh error: $e');
    }
  }

  void _emitSensorValue(StreamController<double?> controller, dynamic raw) {
    if (raw is num) {
      controller.add(raw.toDouble());
    }
  }

  void _pushTemperature(double? value) {
    if (value == null) return;
    _latestTemperature = value;
    _state['temperature'] = value;
    _rememberState('temperature', value);
    _tempCtrl.add(value);
    unawaited(_ensureAutoPlantSyncForHighTemp(reason: 'telemetry'));
  }

  void _pushHumidity(double? value) {
    if (value == null) return;
    _latestHumidity = value;
    _state['humidity'] = value;
    _rememberState('humidity', value);
    _humCtrl.add(value);
  }

  void _pushSoilMoisture(double? value) {
    if (value == null) return;
    _latestSoilMoisture = value;
    _state['soil_moisture'] = value;
    _rememberState('soil_moisture', value);
    _soilCtrl.add(value);
  }

  void _emitTemperatureValue(dynamic raw) {
    if (raw is num) {
      _pushTemperature(raw.toDouble());
    }
  }

  void _emitHumidityValue(dynamic raw) {
    if (raw is num) {
      _pushHumidity(raw.toDouble());
    }
  }

  void _emitSoilMoistureValue(dynamic raw) {
    if (raw is num) {
      _pushSoilMoisture(raw.toDouble());
    }
  }

  Future<void> _refreshRuntimeSnapshot() async {
    if ((AppSessionService.token ?? '').trim().isEmpty) return;
    final snapshotUrl = _resolveRuntimeSnapshotUrl();
    if (snapshotUrl == null) return;

    try {
      final uri = Uri.parse(snapshotUrl).replace(
        queryParameters: <String, String>{'device_id': deviceId},
      );
      final response = await http
          .get(uri, headers: AppSessionService.buildAuthHeaders(json: false))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode >= 400) return;

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return;
      final runtimeRaw = body['runtime'];
      if (runtimeRaw is! Map) return;
      final runtime = Map<String, dynamic>.from(runtimeRaw);

      _emitTemperatureValue(runtime['temperature']);
      _emitHumidityValue(runtime['humidity']);
      _emitSoilMoistureValue(runtime['soil_moisture']);
      _rememberState('temperature', _latestTemperature);
      _rememberState('humidity', _latestHumidity);
      _rememberState('soil_moisture', _latestSoilMoisture);

      if (!_hasCachedControlState && runtime.containsKey('mode')) {
        final mode = runtime['mode']?.toString() ?? 'manual';
        _state['mode'] = mode;
        _rememberState('mode', mode);
        _modeCtrl.add(mode);
      }
      if (!_hasCachedControlState && runtime.containsKey('lamp_pwm')) {
        final lampPwm = (runtime['lamp_pwm'] as num?)?.toInt();
        _state['lamp_pwm'] = lampPwm;
        _rememberState('lamp_pwm', lampPwm);
        _lampPwmCtrl.add(lampPwm);
      }
      if (!_hasCachedControlState && runtime.containsKey('active_plant')) {
        final activePlant = runtime['active_plant']?.toString() ?? '';
        _state['active_plant'] = activePlant;
        _rememberState('active_plant', activePlant);
        _activePlantCtrl.add(activePlant);
      }
      if (!_hasCachedControlState && runtime.containsKey('sprayer_duration')) {
        final duration = (runtime['sprayer_duration'] as num?)?.toInt();
        _state['sprayer_duration'] = duration;
        _rememberState('sprayer_duration', duration);
        _sprayerDurCtrl.add(duration);
      }
      if (!_hasCachedControlState && runtime['sprayer_times'] is List) {
        final list = List<dynamic>.from(runtime['sprayer_times'] as List);
        final times = <String, String>{};
        for (var i = 0; i < list.length; i++) {
          times[i.toString()] = list[i].toString();
        }
        _state['sprayer_times'] = times;
        _rememberState('sprayer_times', times);
        _sprayerTimesCtrl.add(times);
      }
      if (!_hasCachedControlState && runtime['relay'] is Map) {
        final relays = Map<String, dynamic>.from(runtime['relay'] as Map);
        _state['relay'] = relays;
        _rememberState('relay', relays);
        for (final entry in relays.entries) {
          _getRelayCtrl(entry.key).add(entry.value == true);
        }
      }

      final lastSeen = (runtime['last_seen'] as num?)?.toInt();
      if (lastSeen != null && lastSeen > 0) {
        _lastSeenEpoch = lastSeen;
        _rememberState('last_seen', lastSeen);
      } else if (runtime['online'] == true) {
        _lastSeenEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        _rememberState('last_seen', _lastSeenEpoch);
      }
      _evaluateOnline();
      unawaited(_ensureAutoPlantSyncForHighTemp(reason: 'runtime_snapshot'));
    } catch (e) {
      debugPrint('[MQTT] Runtime snapshot refresh error: $e');
    }
  }

  Future<void> _syncManualSchedule({
    int? durationOverride,
    List<String>? timesOverride,
  }) async {
    final duration = durationOverride ??
        (_state['manual'] is Map
            ? ((_state['manual'] as Map)['sprayer_duration'] as num?)?.toInt()
            : null) ??
        10;

    final times = timesOverride ?? _readCachedManualTimes();

    await _postSync('/manual-schedule', {
      'device_id': deviceId,
      'sprayer_duration': duration,
      'sprayer_times': times,
      'light_schedule': _readCachedLightSchedule(),
    });

    _syncActivity(
      action: 'mobile.inkubator.manual_schedule.save',
      description: 'Simpan jadwal manual dari aplikasi mobile',
      metadata: {
        'sprayer_duration': duration,
        'sprayer_times': times,
      },
    );
  }

  Future<void> _syncActivePlantFromApi() async {
    final mode = _state['mode']?.toString() ?? 'manual';
    if (mode != 'auto') {
      _lastAutoSyncSignature = '';
      return;
    }

    final activePlantId = _state['active_plant']?.toString() ?? '';
    if (activePlantId.isEmpty) {
      _lastAutoSyncSignature = '';
      return;
    }

    final plant = await getPlantById(activePlantId);
    if (plant == null) {
      debugPrint('[MQTT] Auto sync skipped: plant $activePlantId belum ada di cache');
      return;
    }

    final plantConfig = _buildPlantConfigPayload(activePlantId, plant);
    final signature = jsonEncode(plantConfig);
    if (signature == _lastAutoSyncSignature) return;

    _lastAutoSyncSignature = signature;
    debugPrint('[MQTT] Auto sync active plant $activePlantId -> watering=${plantConfig['watering_times']}');
    await _sendCommand('set_active_plant', plantConfig);
  }

  Future<void> _ensureAutoPlantSyncForHighTemp({required String reason}) async {
    final mode = _state['mode']?.toString() ?? 'manual';
    if (mode != 'auto') return;

    final activePlantId = _state['active_plant']?.toString() ?? '';
    if (activePlantId.isEmpty) return;

    final temperature = _latestTemperature;
    if (temperature == null) return;

    final fanOn = cachedRelayValue('fan');
    if (fanOn) return;

    final plant = await getPlantById(activePlantId);
    if (plant == null) return;

    final tempOptRaw = plant['temp_optimal'];
    final tempOpt = tempOptRaw is Map
        ? Map<String, dynamic>.from(tempOptRaw)
        : <String, dynamic>{};
    final tempMax = (tempOpt['max'] as num?)?.toDouble() ?? 35.0;
    if (temperature <= tempMax) return;

    final plantConfig = _buildPlantConfigPayload(activePlantId, plant);
    final signature = jsonEncode({
      'reason': reason,
      'plant': plantConfig,
      'temp': temperature.toStringAsFixed(1),
    });
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (signature == _lastAutoRepairSignature &&
        (nowMs - _lastAutoRepairEpochMs) < 30000) {
      return;
    }

    _lastAutoRepairSignature = signature;
    _lastAutoRepairEpochMs = nowMs;
    debugPrint(
      '[MQTT] Auto repair sync active plant $activePlantId '
      'temp=${temperature.toStringAsFixed(1)} tempMax=${tempMax.toStringAsFixed(1)} '
      'reason=$reason',
    );
    await _sendCommand('set_active_plant', plantConfig);
  }

  /// Build plant config payload matching ESP MQTT firmware's set_active_plant format.
  Map<String, dynamic> _buildPlantConfigPayload(String plantId, Map<String, dynamic>? plant) {
    if (plant == null) return {'id': plantId};

    final wateringRaw = plant['watering'];
    final watering = wateringRaw is Map
        ? Map<String, dynamic>.from(wateringRaw)
        : <String, dynamic>{};
    final lightingRaw = plant['lighting'];
    final lighting = lightingRaw is Map
        ? Map<String, dynamic>.from(lightingRaw)
        : <String, dynamic>{};
    final lightCycleRaw = plant['light_cycle'];
    final lightCycle = lightCycleRaw is Map
        ? Map<String, dynamic>.from(lightCycleRaw)
        : <String, dynamic>{};
    final tempOptRaw = plant['temp_optimal'];
    final tempOpt = tempOptRaw is Map
        ? Map<String, dynamic>.from(tempOptRaw)
        : <String, dynamic>{};

    return {
      'id': plantId,
      'temp_optimal_max': (tempOpt['max'] as num?)?.toDouble() ?? 35.0,
      'light_pwm': (plant['light_pwm'] as num?)?.toInt() ?? 60,
      'lighting_start': lighting['start_time']?.toString() ?? '06:00',
      'lighting_end': lighting['end_time']?.toString() ?? '17:00',
      'lighting_days': lighting['days'] is List ? lighting['days'] : [0, 1, 2, 3, 4, 5, 6],
      'dark_days': (lightCycle['dark_days'] as num?)?.toInt() ?? 7,
      'light_days': (lightCycle['light_days'] as num?)?.toInt() ?? 7,
      'cycle_start_date': lightCycle['start_date']?.toString() ?? '',
      'cycle_start_phase': lightCycle['start_phase']?.toString() ?? 'dark',
      'watering_times': _normalizeTimesList(watering['times']),
      'watering_duration': (watering['duration'] as num?)?.toInt() ?? 10,
    };
  }

  Future<void> _syncApplyPlant(String plantId) async {
    final plant = await getPlantById(plantId);
    if (plant == null) return;

    final wateringRaw = plant['watering'];
    final watering = wateringRaw is Map
        ? Map<String, dynamic>.from(wateringRaw)
        : <String, dynamic>{};
    final lightingRaw = plant['lighting'];
    final lighting = lightingRaw is Map
        ? Map<String, dynamic>.from(lightingRaw)
        : <String, dynamic>{};

    final duration = (watering['duration'] as num?)?.toInt() ?? 10;
    final times = _normalizeTimesList(watering['times']);
    final startDate = lighting['start_date']?.toString() ??
        DateTime.now().toIso8601String().split('T').first;
    final startTime = lighting['start_time']?.toString() ?? '06:00';
    final endTime = lighting['end_time']?.toString() ?? '17:00';
    final lampPwm = (plant['light_pwm'] as num?)?.toInt() ?? 60;

    await _postSync('/apply-plant', {
      'device_id': deviceId,
      'active_plant_id': plantId,
      'sprayer_duration': duration,
      'sprayer_times': times,
      'light_schedule': {
        'start_date': startDate,
        'start_time': startTime,
        'end_time': endTime,
        'days': [0, 1, 2, 3, 4, 5, 6],
      },
      'lamp_pwm': lampPwm,
    });
  }

  List<String> _readCachedManualTimes() {
    if (_state['manual'] is Map) {
      final manual = _state['manual'] as Map;
      if (manual['sprayer_times'] is Map) {
        return _orderedTimesFromMap(
          Map<String, dynamic>.from(manual['sprayer_times'] as Map),
        );
      }
    }
    return const ['08:00'];
  }

  Map<String, dynamic> _readCachedLightSchedule() {
    if (_state['manual'] is Map) {
      final manual = _state['manual'] as Map;
      if (manual['light_schedule'] is Map) {
        return Map<String, dynamic>.from(manual['light_schedule'] as Map);
      }
    }
    return {
      'start_date': DateTime.now().toIso8601String().split('T').first,
      'start_time': '06:00',
      'end_time': '17:00',
      'days': [0, 1, 2, 3, 4, 5, 6],
    };
  }

  List<String> _orderedTimesFromMap(Map<String, dynamic> timesMap) {
    final entries = timesMap.entries.toList()
      ..sort((a, b) {
        final ai = int.tryParse(a.key) ?? 0;
        final bi = int.tryParse(b.key) ?? 0;
        return ai.compareTo(bi);
      });
    final times = entries.map((e) => e.value.toString()).toList();
    return times.isEmpty ? const ['08:00'] : times;
  }

  List<String> _normalizeTimesList(dynamic rawTimes) {
    if (rawTimes is List) {
      final out = <String>[];
      for (final value in rawTimes) {
        if (value == null) continue;
        out.add(value.toString());
      }
      return out.isEmpty ? const ['08:00'] : out;
    }
    return const ['08:00'];
  }

  // ── Activity logging ──

  String _formatLocalDateTime(DateTime value) {
    final local = value.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  Future<void> _syncActivity({
    required String action,
    String? description,
    Map<String, dynamic>? metadata,
  }) async {
    await _postActivity({
      'action': action,
      'module': 'inkubator',
      'device_id': deviceId,
      'description': description,
      'metadata': metadata,
      'performed_at': _formatLocalDateTime(DateTime.now()),
    });
  }

  Future<void> _postActivity(Map<String, dynamic> payload) async {
    final hasToken = (AppSessionService.token ?? '').trim().isNotEmpty;
    if (hasToken) {
      await _postSync('/activity', payload);
      return;
    }
    if (!AppConfig.hasSystemActivityKey) return;

    final url = _resolveSystemActivityUrl();
    if (url == null) return;
    try {
      await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'X-System-Key': AppConfig.systemActivityKey,
              'X-Device-Id': deviceId,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('[MQTT] Activity POST error: $e');
    }
  }

  Future<void> _postSync(String path, Map<String, dynamic> payload) async {
    if ((AppSessionService.token ?? '').isEmpty) {
      debugPrint('[MQTT] Sync POST skipped [$path]: token kosong');
      return;
    }
    final syncBaseUrl = _resolveSyncBaseUrl();
    if (syncBaseUrl == null) return;
    try {
      await http
          .post(
            Uri.parse('$syncBaseUrl$path'),
            headers: AppSessionService.buildAuthHeaders(),
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('[MQTT] Sync POST error [$path]: $e');
    }
  }

  Future<void> _deleteSync(String path) async {
    if ((AppSessionService.token ?? '').isEmpty) return;
    final syncBaseUrl = _resolveSyncBaseUrl();
    if (syncBaseUrl == null) return;
    try {
      await http
          .delete(
            Uri.parse('$syncBaseUrl$path'),
            headers: AppSessionService.buildAuthHeaders(json: false),
          )
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('[MQTT] Sync DELETE error [$path]: $e');
    }
  }

  @override
  Future<void> dispose() async {
    _onlineCheckTimer?.cancel();
    _plantsRefreshTimer?.cancel();
    _autoPlantSyncTimer?.cancel();
    _runtimeSnapshotTimer?.cancel();
    _cachePersistTimer?.cancel();
    _telemetrySub?.cancel();
    _statusSub?.cancel();
    _alertSub?.cancel();
    _modeCtrl.close();
    _tempCtrl.close();
    _humCtrl.close();
    _soilCtrl.close();
    _lampPwmCtrl.close();
    _activePlantCtrl.close();
    _sprayerDurCtrl.close();
    _sprayerTimesCtrl.close();
    _onlineCtrl.close();
    _plantsCtrl.close();
    for (final ctrl in _relayCtrl.values) {
      ctrl.close();
    }
  }
}
