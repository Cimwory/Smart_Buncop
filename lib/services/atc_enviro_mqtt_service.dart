import 'dart:async';

import 'mqtt_service.dart';

/// MQTT service for ATC Enviro Control node (NH3/CH4 + relay + auto/manual).
///
/// Topic pattern:
///   buncop/monitoring/{deviceId}/telemetry
///   buncop/monitoring/{deviceId}/status
///   buncop/monitoring/{deviceId}/command
class AtcEnviroMqttService {
  final String deviceId;
  final String area;
  final MqttService _mqtt;

  final _nh3Ctrl = StreamController<double?>.broadcast();
  final _methaneCtrl = StreamController<double?>.broadcast();
  final _modeCtrl = StreamController<String>.broadcast();
  final _relayCtrl = StreamController<bool>.broadcast();
  final _upperCtrl = StreamController<double?>.broadcast();
  final _lowerCtrl = StreamController<double?>.broadcast();
  final _r0Mq135Ctrl = StreamController<double?>.broadcast();
  final _r0Mq2Ctrl = StreamController<double?>.broadcast();
  final _messageCtrl = StreamController<String>.broadcast();
  final _onlineCtrl = StreamController<bool>.broadcast();

  final _state = <String, dynamic>{};

  StreamSubscription? _telemetrySub;
  StreamSubscription? _statusSub;
  Timer? _onlineTimer;
  int _lastSeenEpoch = 0;
  bool _lastOnline = false;

  AtcEnviroMqttService({
    required this.deviceId,
    this.area = 'monitoring',
    MqttService? mqtt,
  }) : _mqtt = mqtt ?? MqttService.instance {
    _init();
  }

  String _topic(String suffix) => _mqtt.topic(area, deviceId, suffix);

  void _init() {
    _telemetrySub = _mqtt.subscribeJson(_topic('telemetry')).listen(_onTelemetry);
    _statusSub = _mqtt.subscribeJson(_topic('status')).listen(_onStatus);
    _onlineTimer = Timer.periodic(const Duration(seconds: 10), (_) => _evaluateOnline());
  }

  void _onTelemetry(Map<String, dynamic> data) {
    _state.addAll(data);

    final nh3Raw = data['nh3'] ?? data['nH3'];
    if (nh3Raw is num) {
      _nh3Ctrl.add(nh3Raw.toDouble());
    }

    final methaneRaw = data['methane'] ?? data['ch4'];
    if (methaneRaw is num) {
      _methaneCtrl.add(methaneRaw.toDouble());
    }

    final ts = data['timestamp'] as int? ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _lastSeenEpoch = ts;
    _evaluateOnline();
  }

  void _onStatus(Map<String, dynamic> data) {
    _state.addAll(data);

    final mode = data['mode']?.toString();
    if (mode != null && mode.isNotEmpty) {
      _modeCtrl.add(mode);
    }

    bool? relay;
    final relayRaw = data['relay'];
    if (relayRaw is bool) {
      relay = relayRaw;
    } else if (relayRaw is Map) {
      final map = Map<String, dynamic>.from(relayRaw);
      relay = map['relay1'] == true || map['main'] == true || map['fan'] == true;
    }
    if (relay != null) {
      _relayCtrl.add(relay);
    }

    final upperRaw = data['nh3_upper_limit'];
    if (upperRaw is num) {
      _upperCtrl.add(upperRaw.toDouble());
    }
    final lowerRaw = data['nh3_lower_limit'];
    if (lowerRaw is num) {
      _lowerCtrl.add(lowerRaw.toDouble());
    }
    final r0Mq135Raw = data['r0_mq135'];
    if (r0Mq135Raw is num) {
      _r0Mq135Ctrl.add(r0Mq135Raw.toDouble());
    }
    final r0Mq2Raw = data['r0_mq2'];
    if (r0Mq2Raw is num) {
      _r0Mq2Ctrl.add(r0Mq2Raw.toDouble());
    }

    final msg = data['system_message']?.toString();
    if (msg != null && msg.isNotEmpty) {
      _messageCtrl.add(msg);
    }

    if (data['last_seen'] is num) {
      _lastSeenEpoch = (data['last_seen'] as num).toInt();
      _evaluateOnline();
    }
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
      _onlineCtrl.add(online);
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

  Stream<double?> nh3Stream() => _nh3Ctrl.stream;
  Stream<double?> methaneStream() => _methaneCtrl.stream;
  Stream<String> modeStream() => _modeCtrl.stream;
  Stream<bool> relayStream() => _relayCtrl.stream;
  Stream<double?> nh3UpperLimitStream() => _upperCtrl.stream;
  Stream<double?> nh3LowerLimitStream() => _lowerCtrl.stream;
  Stream<double?> r0Mq135Stream() => _r0Mq135Ctrl.stream;
  Stream<double?> r0Mq2Stream() => _r0Mq2Ctrl.stream;
  Stream<String> systemMessageStream() => _messageCtrl.stream;
  Stream<bool> onlineStream() => _onlineCtrl.stream;

  Future<void> setMode(bool auto) async {
    _modeCtrl.add(auto ? 'auto' : 'manual');
    _sendCommand('set_mode', auto ? 'auto' : 'manual');
  }

  Future<void> setRelay(bool value) async {
    _relayCtrl.add(value);
    _sendCommand('set_relay', value);
  }

  Future<void> setNh3Limits({
    required double upper,
    required double lower,
  }) async {
    _upperCtrl.add(upper);
    _lowerCtrl.add(lower);
    _sendCommand('set_limits', {
      'nh3_upper_limit': double.parse(upper.toStringAsFixed(2)),
      'nh3_lower_limit': double.parse(lower.toStringAsFixed(2)),
    });
  }

  Future<void> startCalibration() async {
    _sendCommand('start_calibration', true);
  }

  Future<void> requestStatus() async {
    _sendCommand('get_status', true);
  }

  Future<void> setR0Mq135(double value) async {
    _sendCommand('set_config', value, extra: {'config_key': 'r0_mq135'});
  }

  Future<void> setR0Mq2(double value) async {
    _sendCommand('set_config', value, extra: {'config_key': 'r0_mq2'});
  }

  void dispose() {
    _telemetrySub?.cancel();
    _statusSub?.cancel();
    _onlineTimer?.cancel();
    _nh3Ctrl.close();
    _methaneCtrl.close();
    _modeCtrl.close();
    _relayCtrl.close();
    _upperCtrl.close();
    _lowerCtrl.close();
    _r0Mq135Ctrl.close();
    _r0Mq2Ctrl.close();
    _messageCtrl.close();
    _onlineCtrl.close();
  }
}
