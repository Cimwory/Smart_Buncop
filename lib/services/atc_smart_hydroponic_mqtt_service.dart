import 'dart:async';

import 'mqtt_service.dart';

class AtcSmartHydroponicMqttService {
  final String deviceId;
  final String area;
  final MqttService _mqtt;

  final _phCtrl = StreamController<double?>.broadcast();
  final _tdsCtrl = StreamController<double?>.broadcast();
  final _modeCtrl = StreamController<String>.broadcast();
  final _relayNutrientCtrl = StreamController<bool>.broadcast();
  final _relayPhDownCtrl = StreamController<bool>.broadcast();
  final _phMinCtrl = StreamController<double?>.broadcast();
  final _phMaxCtrl = StreamController<double?>.broadcast();
  final _tdsMinCtrl = StreamController<double?>.broadcast();
  final _tdsMaxCtrl = StreamController<double?>.broadcast();
  final _messageCtrl = StreamController<String>.broadcast();
  final _onlineCtrl = StreamController<bool>.broadcast();

  StreamSubscription? _telemetrySub;
  StreamSubscription? _statusSub;
  Timer? _onlineTimer;
  int _lastSeenEpoch = 0;
  bool _lastOnline = false;

  AtcSmartHydroponicMqttService({
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
    final phRaw = data['pH'] ?? data['ph'];
    if (phRaw is num) {
      _phCtrl.add(phRaw.toDouble());
    }

    final tdsRaw = data['tds'];
    if (tdsRaw is num) {
      _tdsCtrl.add(tdsRaw.toDouble());
    }

    final ts = data['timestamp'] as int? ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _lastSeenEpoch = ts;
    _evaluateOnline();
  }

  void _onStatus(Map<String, dynamic> data) {
    final modeRaw = data['mode']?.toString().toLowerCase();
    if (modeRaw == 'auto' || modeRaw == 'manual') {
      _modeCtrl.add(modeRaw!);
    } else if (data['auto_mode'] is bool) {
      _modeCtrl.add((data['auto_mode'] as bool) ? 'auto' : 'manual');
    }

    bool? relayNutrient;
    bool? relayPhDown;

    final relayRaw = data['relay'];
    if (relayRaw is Map) {
      final map = Map<String, dynamic>.from(relayRaw);
      relayNutrient = map['relay_nutrient'] == true || map['nutrient'] == true;
      relayPhDown = map['relay_ph_down'] == true || map['ph_down'] == true;
    }

    if (data['relayNutrient'] is bool) relayNutrient = data['relayNutrient'] as bool;
    if (data['relayPhDown'] is bool) relayPhDown = data['relayPhDown'] as bool;

    if (relayNutrient != null) _relayNutrientCtrl.add(relayNutrient);
    if (relayPhDown != null) _relayPhDownCtrl.add(relayPhDown);

    final phMinRaw = data['pH_min'] ?? data['ph_min'];
    if (phMinRaw is num) _phMinCtrl.add(phMinRaw.toDouble());

    final phMaxRaw = data['pH_max'] ?? data['ph_max'];
    if (phMaxRaw is num) _phMaxCtrl.add(phMaxRaw.toDouble());

    final tdsMinRaw = data['tds_min'];
    if (tdsMinRaw is num) _tdsMinCtrl.add(tdsMinRaw.toDouble());

    final tdsMaxRaw = data['tds_max'];
    if (tdsMaxRaw is num) _tdsMaxCtrl.add(tdsMaxRaw.toDouble());

    final message = data['system_message']?.toString() ?? data['msg']?.toString();
    if (message != null && message.isNotEmpty) {
      _messageCtrl.add(message);
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

  Stream<double?> phStream() => _phCtrl.stream;
  Stream<double?> tdsStream() => _tdsCtrl.stream;
  Stream<String> modeStream() => _modeCtrl.stream;
  Stream<bool> relayNutrientStream() => _relayNutrientCtrl.stream;
  Stream<bool> relayPhDownStream() => _relayPhDownCtrl.stream;
  Stream<double?> phMinStream() => _phMinCtrl.stream;
  Stream<double?> phMaxStream() => _phMaxCtrl.stream;
  Stream<double?> tdsMinStream() => _tdsMinCtrl.stream;
  Stream<double?> tdsMaxStream() => _tdsMaxCtrl.stream;
  Stream<String> systemMessageStream() => _messageCtrl.stream;
  Stream<bool> onlineStream() => _onlineCtrl.stream;

  Future<void> setMode(bool auto) async {
    _modeCtrl.add(auto ? 'auto' : 'manual');
    _sendCommand('set_mode', auto ? 'auto' : 'manual');
  }

  Future<void> setRelayNutrient(bool value) async {
    _relayNutrientCtrl.add(value);
    _sendCommand('set_relay', value, extra: {'relay': 'relay_nutrient'});
  }

  Future<void> setRelayPhDown(bool value) async {
    _relayPhDownCtrl.add(value);
    _sendCommand('set_relay', value, extra: {'relay': 'relay_ph_down'});
  }

  Future<void> setLimits({
    required double phMin,
    required double phMax,
    required double tdsMin,
    required double tdsMax,
  }) async {
    _phMinCtrl.add(phMin);
    _phMaxCtrl.add(phMax);
    _tdsMinCtrl.add(tdsMin);
    _tdsMaxCtrl.add(tdsMax);
    _sendCommand('set_limits', {
      'pH_min': double.parse(phMin.toStringAsFixed(2)),
      'pH_max': double.parse(phMax.toStringAsFixed(2)),
      'tds_min': double.parse(tdsMin.toStringAsFixed(1)),
      'tds_max': double.parse(tdsMax.toStringAsFixed(1)),
    });
  }

  Future<void> requestStatus() async {
    _sendCommand('get_status', true);
  }

  void dispose() {
    _telemetrySub?.cancel();
    _statusSub?.cancel();
    _onlineTimer?.cancel();
    _phCtrl.close();
    _tdsCtrl.close();
    _modeCtrl.close();
    _relayNutrientCtrl.close();
    _relayPhDownCtrl.close();
    _phMinCtrl.close();
    _phMaxCtrl.close();
    _tdsMinCtrl.close();
    _tdsMaxCtrl.close();
    _messageCtrl.close();
    _onlineCtrl.close();
  }
}
