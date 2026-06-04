import 'dart:async';

import 'mqtt_service.dart';

class AtcIrrigationMqttService {
  static final Map<String, Map<String, dynamic>> _latestByDevice = {};
  static const int _historyLimit = 180;
  static final Map<String, Map<String, List<AtcIrrigationHistoryPoint>>> _historyByDevice = {};

  final String deviceId;
  final String area;
  final MqttService _mqtt;

  final _tempCtrl = StreamController<double?>.broadcast();
  final _humCtrl = StreamController<double?>.broadcast();
  final _soilCtrl = StreamController<double?>.broadcast();
  final _relayPumpCtrl = StreamController<bool>.broadcast();
  final _relaySprayerCtrl = StreamController<bool>.broadcast();
  final _pumpScheduleCtrl = StreamController<List<String>>.broadcast();
  final _sprayerScheduleCtrl = StreamController<List<String>>.broadcast();
  final _pumpDurationCtrl = StreamController<int?>.broadcast();
  final _sprayerDurationCtrl = StreamController<int?>.broadcast();
  final _pumpRemainingCtrl = StreamController<int?>.broadcast();
  final _sprayerRemainingCtrl = StreamController<int?>.broadcast();
  final _messageCtrl = StreamController<String>.broadcast();
  final _onlineCtrl = StreamController<bool>.broadcast();

  StreamSubscription? _telemetrySub;
  StreamSubscription? _statusSub;
  Timer? _onlineTimer;
  int _lastSeenEpoch = 0;
  bool _lastOnline = false;

  AtcIrrigationMqttService({
    required this.deviceId,
    this.area = 'monitoring',
    MqttService? mqtt,
  }) : _mqtt = mqtt ?? MqttService.instance {
    _seedFromCache();
    _init();
  }

  String _topic(String suffix) => _mqtt.topic(area, deviceId, suffix);

  void _init() {
    _telemetrySub = _mqtt.subscribeJson(_topic('telemetry')).listen(_onTelemetry);
    _statusSub = _mqtt.subscribeJson(_topic('status')).listen(_onStatus);
    _onlineTimer = Timer.periodic(const Duration(seconds: 10), (_) => _evaluateOnline());
  }

  void _onTelemetry(Map<String, dynamic> data) {
    final ts = data['timestamp'] as int? ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);

    final tempRaw = data['temperature'];
    if (tempRaw is num) {
      final value = tempRaw.toDouble();
      _remember('temperature', value);
      _rememberHistory('temperature', value, ts);
      _tempCtrl.add(value);
    }

    final humRaw = data['humidity'];
    if (humRaw is num) {
      final value = humRaw.toDouble();
      _remember('humidity', value);
      _rememberHistory('humidity', value, ts);
      _humCtrl.add(value);
    }

    final soilRaw = data['soil_moisture'] ?? data['soilMoisture'];
    if (soilRaw is num) {
      final value = soilRaw.toDouble();
      _remember('soil_moisture', value);
      _rememberHistory('soil_moisture', value, ts);
      _soilCtrl.add(value);
    }

    _lastSeenEpoch = ts;
    _remember('last_seen', ts);
    _evaluateOnline();
  }

  void _onStatus(Map<String, dynamic> data) {
    bool? relayPump;
    bool? relaySprayer;

    final relayRaw = data['relay'];
    if (relayRaw is Map) {
      final map = Map<String, dynamic>.from(relayRaw);
      relayPump = map['relay_pump'] == true || map['pump'] == true;
      relaySprayer = map['relay_sprayer'] == true || map['sprayer'] == true;
    }

    if (data['relayPumpState'] is bool) relayPump = data['relayPumpState'] as bool;
    if (data['relaySprayerState'] is bool) relaySprayer = data['relaySprayerState'] as bool;

    if (relayPump != null) {
      _remember('relay_pump', relayPump);
      _relayPumpCtrl.add(relayPump);
    }
    if (relaySprayer != null) {
      _remember('relay_sprayer', relaySprayer);
      _relaySprayerCtrl.add(relaySprayer);
    }

    final scheduleRaw = data['schedule'];
    if (scheduleRaw is Map) {
      final schedule = Map<String, dynamic>.from(scheduleRaw);
      final pumpTimes = _normalizeTimes(schedule['pump_times']);
      final sprayerTimes = _normalizeTimes(schedule['sprayer_times']);
      _remember('pump_times', pumpTimes);
      _remember('sprayer_times', sprayerTimes);
      _pumpScheduleCtrl.add(pumpTimes);
      _sprayerScheduleCtrl.add(sprayerTimes);

      final pumpDuration = schedule['pump_duration'];
      if (pumpDuration is num) {
        final value = pumpDuration.toInt();
        _remember('pump_duration', value);
        _pumpDurationCtrl.add(value);
      }

      final sprayerDuration = schedule['sprayer_duration'];
      if (sprayerDuration is num) {
        final value = sprayerDuration.toInt();
        _remember('sprayer_duration', value);
        _sprayerDurationCtrl.add(value);
      }

      final pumpRemaining = schedule['pump_remaining'];
      final pumpRemainingValue = pumpRemaining is num ? pumpRemaining.toInt() : null;
      _remember('pump_remaining', pumpRemainingValue);
      _pumpRemainingCtrl.add(pumpRemainingValue);

      final sprayerRemaining = schedule['sprayer_remaining'];
      final sprayerRemainingValue = sprayerRemaining is num ? sprayerRemaining.toInt() : null;
      _remember('sprayer_remaining', sprayerRemainingValue);
      _sprayerRemainingCtrl.add(sprayerRemainingValue);
    } else {
      final pumpDuration = data['pump_duration'];
      if (pumpDuration is num) {
        final value = pumpDuration.toInt();
        _remember('pump_duration', value);
        _pumpDurationCtrl.add(value);
      }
      final sprayerDuration = data['sprayer_duration'];
      if (sprayerDuration is num) {
        final value = sprayerDuration.toInt();
        _remember('sprayer_duration', value);
        _sprayerDurationCtrl.add(value);
      }
    }

    final message = data['system_message']?.toString() ?? data['msg']?.toString();
    if (message != null && message.isNotEmpty) {
      _remember('system_message', message);
      _messageCtrl.add(message);
    }

    if (data['last_seen'] is num) {
      _lastSeenEpoch = (data['last_seen'] as num).toInt();
      _remember('last_seen', _lastSeenEpoch);
      _evaluateOnline();
    }
  }

  List<String> _normalizeTimes(dynamic raw) {
    final items = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final value = item?.toString().trim() ?? '';
        if (_isValidTime(value)) items.add(value);
      }
    } else if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final keys = map.keys.toList()
        ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
      for (final key in keys) {
        final value = map[key]?.toString().trim() ?? '';
        if (_isValidTime(value)) items.add(value);
      }
    }

    final unique = items.toSet().toList()..sort();
    return unique;
  }

  bool _isValidTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return false;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    return hour != null &&
        minute != null &&
        hour >= 0 &&
        hour <= 23 &&
        minute >= 0 &&
        minute <= 59;
  }

  void _evaluateOnline() {
    const thresholdSec = 45;
    if (_lastSeenEpoch <= 0) {
      if (_lastOnline) {
        _lastOnline = false;
        _onlineCtrl.add(false);
      }
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final online = (now - _lastSeenEpoch) <= thresholdSec;
    if (online != _lastOnline) {
      _lastOnline = online;
      _remember('online', online);
      _onlineCtrl.add(online);
    }
  }

  void _remember(String key, dynamic value) {
    final cache = _latestByDevice.putIfAbsent(deviceId, () => <String, dynamic>{});
    cache[key] = value;
  }

  void _rememberHistory(String field, double value, int timestamp) {
    final fields = _historyByDevice.putIfAbsent(
      deviceId,
      () => <String, List<AtcIrrigationHistoryPoint>>{},
    );
    final points = fields.putIfAbsent(field, () => <AtcIrrigationHistoryPoint>[]);
    points.add(AtcIrrigationHistoryPoint(timestamp: timestamp, value: value));
    if (points.length > _historyLimit) {
      points.removeRange(0, points.length - _historyLimit);
    }
  }

  void _seedFromCache() {
    final cache = _latestByDevice[deviceId];
    if (cache == null) return;
    final lastSeen = cache['last_seen'];
    if (lastSeen is int) {
      _lastSeenEpoch = lastSeen;
    }
    final online = cache['online'];
    if (online is bool) {
      _lastOnline = online;
    }
  }

  void _sendCommand(String type, dynamic value, {Map<String, dynamic>? extra}) {
    final payload = <String, dynamic>{
      'type': type,
      'value': value,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (extra != null) payload.addAll(extra);
    _mqtt.publishJson(_topic('command'), payload);
  }

  Stream<T> _replayStream<T>(StreamController<T> source, String key) {
    return Stream<T>.multi(
      (controller) {
        final cache = _latestByDevice[deviceId];
        if (cache != null && cache.containsKey(key)) {
          final value = cache[key];
          if (value is T) {
            controller.add(value);
          }
        }
        final sub = source.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      },
      isBroadcast: true,
    );
  }

  Stream<double?> temperatureStream() => _replayStream<double?>(_tempCtrl, 'temperature');
  Stream<double?> humidityStream() => _replayStream<double?>(_humCtrl, 'humidity');
  Stream<double?> soilMoistureStream() => _replayStream<double?>(_soilCtrl, 'soil_moisture');
  Stream<bool> relayPumpStream() => _replayStream<bool>(_relayPumpCtrl, 'relay_pump');
  Stream<bool> relaySprayerStream() => _replayStream<bool>(_relaySprayerCtrl, 'relay_sprayer');
  Stream<List<String>> pumpScheduleStream() => _replayStream<List<String>>(_pumpScheduleCtrl, 'pump_times');
  Stream<List<String>> sprayerScheduleStream() => _replayStream<List<String>>(_sprayerScheduleCtrl, 'sprayer_times');
  Stream<int?> pumpDurationStream() => _replayStream<int?>(_pumpDurationCtrl, 'pump_duration');
  Stream<int?> sprayerDurationStream() => _replayStream<int?>(_sprayerDurationCtrl, 'sprayer_duration');
  Stream<int?> pumpRemainingStream() => _replayStream<int?>(_pumpRemainingCtrl, 'pump_remaining');
  Stream<int?> sprayerRemainingStream() => _replayStream<int?>(_sprayerRemainingCtrl, 'sprayer_remaining');
  Stream<String> systemMessageStream() => _replayStream<String>(_messageCtrl, 'system_message');
  Stream<bool> onlineStream() => _replayStream<bool>(_onlineCtrl, 'online');

  List<AtcIrrigationHistoryPoint> historyFor(String field) {
    final fields = _historyByDevice[deviceId];
    if (fields == null) return const <AtcIrrigationHistoryPoint>[];
    return List<AtcIrrigationHistoryPoint>.unmodifiable(
      fields[field] ?? const <AtcIrrigationHistoryPoint>[],
    );
  }

  Future<void> setPumpSchedule({
    required List<String> times,
    required int durationSec,
  }) async {
    _pumpScheduleCtrl.add(List<String>.from(times)..sort());
    _pumpDurationCtrl.add(durationSec);
    _sendCommand('sync_state', {
      'control_mode': 'schedule',
      'schedule': {
        'pump_times': times,
        'pump_duration': durationSec,
      },
    });
  }

  Future<void> setSprayerSchedule({
    required List<String> times,
    required int durationSec,
  }) async {
    _sprayerScheduleCtrl.add(List<String>.from(times)..sort());
    _sprayerDurationCtrl.add(durationSec);
    _sendCommand('sync_state', {
      'control_mode': 'schedule',
      'schedule': {
        'sprayer_times': times,
        'sprayer_duration': durationSec,
      },
    });
  }

  Future<void> triggerRelayNow({
    required String relay,
    required int durationSec,
  }) async {
    if (relay == 'relay_pump') {
      _relayPumpCtrl.add(true);
    } else if (relay == 'relay_sprayer') {
      _relaySprayerCtrl.add(true);
    }
    _sendCommand('set_relay', true, extra: {
      'relay': relay,
      'duration_sec': durationSec,
    });
  }

  Future<void> setRelayState({
    required String relay,
    required bool enabled,
    int durationSec = 30,
  }) async {
    if (relay == 'relay_pump') {
      _relayPumpCtrl.add(enabled);
    } else if (relay == 'relay_sprayer') {
      _relaySprayerCtrl.add(enabled);
    }

    _sendCommand('set_relay', enabled, extra: {
      'relay': relay,
      'duration_sec': durationSec,
    });
  }

  Future<void> requestStatus() async {
    _sendCommand('get_status', true);
  }

  void dispose() {
    _telemetrySub?.cancel();
    _statusSub?.cancel();
    _onlineTimer?.cancel();
    _tempCtrl.close();
    _humCtrl.close();
    _soilCtrl.close();
    _relayPumpCtrl.close();
    _relaySprayerCtrl.close();
    _pumpScheduleCtrl.close();
    _sprayerScheduleCtrl.close();
    _pumpDurationCtrl.close();
    _sprayerDurationCtrl.close();
    _pumpRemainingCtrl.close();
    _sprayerRemainingCtrl.close();
    _messageCtrl.close();
    _onlineCtrl.close();
  }
}

class AtcIrrigationHistoryPoint {
  final int timestamp;
  final double value;

  const AtcIrrigationHistoryPoint({
    required this.timestamp,
    required this.value,
  });
}
