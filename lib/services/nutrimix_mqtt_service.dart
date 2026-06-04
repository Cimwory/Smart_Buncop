import 'dart:async';

import '../services/mqtt_service.dart';
import '../config/app_config.dart';

/// MQTT-based nutrimix IoT service.
/// Replaces the old _NutrimixIoTService.
///
/// Topic structure:
///   buncop/nutrimix/{deviceId}/telemetry — weight, sensor data
///   buncop/nutrimix/{deviceId}/status    — process state, relay states, config
///   buncop/nutrimix/{deviceId}/command   — start/stop, config changes
class NutrimixMqttService {
  final String deviceId;
  final MqttService _mqtt;

  // ── Cached state ──
  final _state = <String, dynamic>{};

  // ── Stream controllers for individual fields ──
  final _weightCtrl = StreamController<double>.broadcast();
  final _targetWeightCtrl = StreamController<int?>.broadcast();
  final _processStateCtrl = StreamController<String>.broadcast();
  final _screwCtrl = StreamController<bool>.broadcast();
  final _trimmerCtrl = StreamController<bool>.broadcast();
  final _servoAngleCtrl = StreamController<int>.broadcast();
  final _zeroTolCtrl = StreamController<double>.broadcast();
  final _targetTolCtrl = StreamController<double>.broadcast();
  final _servoOpenAngleCtrl = StreamController<int>.broadcast();
  final _servoDurationCtrl = StreamController<int>.broadcast();
  final _trimmerDurationCtrl = StreamController<int>.broadcast();
  final _onlineCtrl = StreamController<bool>.broadcast();

  int _lastSeenEpoch = 0;
  bool _lastOnline = false;
  Timer? _onlineTimer;

  StreamSubscription? _telemetrySub;
  StreamSubscription? _statusSub;

  NutrimixMqttService(this.deviceId, {MqttService? mqtt})
      : _mqtt = mqtt ?? MqttService.instance {
    _init();
  }

  String _topic(String suffix) =>
      '${AppConfig.mqttTopicPrefix}/nutrimix/$deviceId/$suffix';

  void _init() {
    _telemetrySub = _mqtt.subscribeJson(_topic('telemetry')).listen(_onTelemetry);
    _statusSub = _mqtt.subscribeJson(_topic('status')).listen(_onStatus);
    _onlineTimer = Timer.periodic(const Duration(seconds: 10), (_) => _evaluateOnline());
  }

  void _onTelemetry(Map<String, dynamic> data) {
    if (data.containsKey('weight_g')) {
      _weightCtrl.add((data['weight_g'] as num).toDouble());
    }
    _lastSeenEpoch = data['timestamp'] as int? ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _evaluateOnline();
  }

  void _onStatus(Map<String, dynamic> data) {
    _state.addAll(data);

    if (data.containsKey('process_state')) {
      _processStateCtrl.add(data['process_state'].toString());
    }
    if (data.containsKey('target_weight_g')) {
      _targetWeightCtrl.add((data['target_weight_g'] as num?)?.toInt());
    }
    if (data.containsKey('relay') && data['relay'] is Map) {
      final relays = data['relay'] as Map;
      if (relays.containsKey('screw')) _screwCtrl.add(relays['screw'] == true);
      if (relays.containsKey('trimmer')) _trimmerCtrl.add(relays['trimmer'] == true);
    }
    if (data.containsKey('servo_angle')) {
      _servoAngleCtrl.add((data['servo_angle'] as num).toInt());
    }

    // Config values
    final config = data['config'] is Map ? data['config'] as Map : data;
    if (config.containsKey('zero_tol_g')) {
      _zeroTolCtrl.add((config['zero_tol_g'] as num).toDouble());
    }
    if (config.containsKey('target_tol_g')) {
      _targetTolCtrl.add((config['target_tol_g'] as num).toDouble());
    }
    if (config.containsKey('servo_open_angle_deg')) {
      _servoOpenAngleCtrl.add((config['servo_open_angle_deg'] as num).toInt());
    }
    if (config.containsKey('servo_open_duration_s')) {
      _servoDurationCtrl.add((config['servo_open_duration_s'] as num).toInt());
    }
    if (config.containsKey('trimmer_duration_s')) {
      _trimmerDurationCtrl.add((config['trimmer_duration_s'] as num).toInt());
    }

    if (data.containsKey('last_seen')) {
      _lastSeenEpoch = (data['last_seen'] as num?)?.toInt() ?? 0;
      _evaluateOnline();
    }
  }

  void _evaluateOnline() {
    const threshold = 30;
    if (_lastSeenEpoch <= 0) {
      if (_lastOnline) { _lastOnline = false; _onlineCtrl.add(false); }
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final online = (now - _lastSeenEpoch) <= threshold;
    if (online != _lastOnline) { _lastOnline = online; _onlineCtrl.add(online); }
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

  // ── Streams ──
  Stream<double> filteredWeightStream() => _weightCtrl.stream;
  Stream<int?> targetWeightStream() => _targetWeightCtrl.stream;
  Stream<String> processStateStream() => _processStateCtrl.stream;
  Stream<bool> screwRelayStream() => _screwCtrl.stream;
  Stream<bool> trimmerRelayStream() => _trimmerCtrl.stream;
  Stream<int> servoAngleStream() => _servoAngleCtrl.stream;
  Stream<double> zeroToleranceStream() => _zeroTolCtrl.stream;
  Stream<double> targetToleranceStream() => _targetTolCtrl.stream;
  Stream<int> servoOpenAngleStream() => _servoOpenAngleCtrl.stream;
  Stream<int> servoDurationStream() => _servoDurationCtrl.stream;
  Stream<int> trimmerDurationStream() => _trimmerDurationCtrl.stream;
  Stream<bool> espOnlineStream() => _onlineCtrl.stream;

  // ── Commands ──
  Future<void> startBatch({required int targetWeight}) async {
    _sendCommand('nutrimix_start', targetWeight);
  }

  Future<void> emergencyStop() async {
    _sendCommand('nutrimix_stop', null);
  }

  Future<void> setServoOpenAngle(int degree) async {
    _sendCommand('set_config', degree.clamp(0, 180),
        extra: {'config_key': 'servo_open_angle_deg'});
  }

  Future<void> setServoOpenDuration(int seconds) async {
    _sendCommand('set_config', seconds.clamp(1, 30),
        extra: {'config_key': 'servo_open_duration_s'});
  }

  Future<void> setTrimmerDuration(int seconds) async {
    _sendCommand('set_config', seconds.clamp(1, 120),
        extra: {'config_key': 'trimmer_duration_s'});
  }

  Future<void> setZeroTolerance(double value) async {
    _sendCommand('set_config', double.parse(value.toStringAsFixed(2)),
        extra: {'config_key': 'zero_tol_g'});
  }

  Future<void> setTargetTolerance(double value) async {
    _sendCommand('set_config', double.parse(value.toStringAsFixed(2)),
        extra: {'config_key': 'target_tol_g'});
  }

  void dispose() {
    _onlineTimer?.cancel();
    _telemetrySub?.cancel();
    _statusSub?.cancel();
    _weightCtrl.close();
    _targetWeightCtrl.close();
    _processStateCtrl.close();
    _screwCtrl.close();
    _trimmerCtrl.close();
    _servoAngleCtrl.close();
    _zeroTolCtrl.close();
    _targetTolCtrl.close();
    _servoOpenAngleCtrl.close();
    _servoDurationCtrl.close();
    _trimmerDurationCtrl.close();
    _onlineCtrl.close();
  }
}
