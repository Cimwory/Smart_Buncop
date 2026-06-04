import 'dart:async';

import 'mqtt_service.dart';

class IndoorFarmingMqttService {
  static const String defaultDeviceId = 'indoor_farming_sensor';
  static const String defaultArea = 'indoor_farming';
  static const int _historyLimit = 120;
  static const List<String> relayKeys = <String>[
    'do1',
    'do2',
    'do3',
    'do4',
    'do5',
    'do6',
    'do7',
  ];

  static final Map<String, Map<String, double?>> _latestByNode = {};
  static final Map<String, Map<String, List<IndoorHistoryPoint>>> _historyByNode = {};
  static final Map<String, Map<String, bool>> _relayByNode = {};
  static final Map<String, IndoorAutoConfig> _autoByNode = {};
  static final Map<String, IndoorWaterLevelState> _waterLevelByNode = {};

  final String deviceId;
  final String area;
  final MqttService _mqtt;

  final _temperatureCtrl = StreamController<double?>.broadcast();
  final _ecMsCtrl = StreamController<double?>.broadcast();
  final _ecUsCtrl = StreamController<double?>.broadcast();
  final _ppmCtrl = StreamController<double?>.broadcast();
  final _doCtrl = StreamController<double?>.broadcast();
  final _tdsCtrl = StreamController<double?>.broadcast();
  final _phCtrl = StreamController<double?>.broadcast();
  final _onlineCtrl = StreamController<bool>.broadcast();
  final _messageCtrl = StreamController<String>.broadcast();
  final _relayCtrl = StreamController<Map<String, bool>>.broadcast();
  final _autoCtrl = StreamController<IndoorAutoConfig>.broadcast();
  final _waterLevelCtrl = StreamController<IndoorWaterLevelState>.broadcast();

  StreamSubscription? _telemetrySub;
  StreamSubscription? _statusSub;
  Timer? _onlineTimer;
  int _lastSeenEpoch = 0;
  bool _lastOnline = false;
  String _lastMessage = 'Sensor indoor farming aktif';

  IndoorFarmingMqttService({
    this.deviceId = defaultDeviceId,
    this.area = defaultArea,
    MqttService? mqtt,
  }) : _mqtt = mqtt ?? MqttService.instance {
    _init();
  }

  String get _nodeKey => '$area/$deviceId';
  String _topic(String suffix) => _mqtt.topic(area, deviceId, suffix);

  double? get cachedTemperature => _latest('temperature');
  double? get cachedEcMs => _latest('ec_ms');
  double? get cachedEcUs => _latest('ec_us');
  double? get cachedPpm => _latest('ppm');
  double? get cachedDo => _latest('do');
  double? get cachedTds => _latest('tds');
  double? get cachedPh => _latest('ph');
  bool get cachedOnline => _lastOnline;
  String get cachedMessage => _lastMessage;
  Map<String, bool> get cachedRelayStates => Map<String, bool>.unmodifiable(
        _relayByNode[_nodeKey] ?? _emptyRelayStates(),
      );
  IndoorAutoConfig get cachedAutoConfig => _autoByNode[_nodeKey] ?? const IndoorAutoConfig();
  IndoorWaterLevelState get cachedWaterLevel =>
      _waterLevelByNode[_nodeKey] ?? const IndoorWaterLevelState();

  void _init() {
    _seedFromCache();
    unawaited(_mqtt.connect());
    _telemetrySub = _mqtt.subscribeJson(_topic('telemetry')).listen(_onTelemetry);
    _statusSub = _mqtt.subscribeJson(_topic('status')).listen(_onStatus);
    _onlineTimer = Timer.periodic(const Duration(seconds: 10), (_) => _evaluateOnline());
  }

  void _seedFromCache() {
    final latest = _latestByNode[_nodeKey];
    if (latest != null) {
      _emitAll(latest);
    }
    _relayCtrl.add(cachedRelayStates);
    _autoCtrl.add(cachedAutoConfig);
    _waterLevelCtrl.add(cachedWaterLevel);
  }

  double? _latest(String key) => _latestByNode[_nodeKey]?[key];

  void _emitAll(Map<String, double?> latest) {
    _temperatureCtrl.add(latest['temperature']);
    _ecMsCtrl.add(latest['ec_ms']);
    _ecUsCtrl.add(latest['ec_us']);
    _ppmCtrl.add(latest['ppm']);
    _doCtrl.add(latest['do']);
    _tdsCtrl.add(latest['tds']);
    _phCtrl.add(latest['ph']);
  }

  void _onTelemetry(Map<String, dynamic> data) {
    final timestamp = (data['timestamp'] as num?)?.toInt() ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);

    final message = data['system_message']?.toString() ?? data['msg']?.toString();
    if (message != null && message.isNotEmpty) {
      _lastMessage = message;
      _messageCtrl.add(message);
    }

    _handleNumericField('temperature', data['temperature'], timestamp, _temperatureCtrl);
    _handleNumericField('ec_ms', data['ec_ms'] ?? data['ec'], timestamp, _ecMsCtrl);
    _handleNumericField('ec_us', data['ec_us'], timestamp, _ecUsCtrl);
    _handleNumericField('ppm', data['ppm'], timestamp, _ppmCtrl);
    _handleNumericField('do', data['do'], timestamp, _doCtrl);
    _handleNumericField('tds', data['tds'], timestamp, _tdsCtrl);
    _handleNumericField('ph', data['ph'] ?? data['pH'], timestamp, _phCtrl);
    _handleRelayPayload(data['relay']);
    _mergeAutoPayload(data);
    _handleTelemetryWaterLevel(data);

    _lastSeenEpoch = timestamp;
    _evaluateOnline();
  }

  void _onStatus(Map<String, dynamic> data) {
    if (data['last_seen'] is num) {
      _lastSeenEpoch = (data['last_seen'] as num).toInt();
    }

    final message = data['system_message']?.toString();
    if (message != null && message.isNotEmpty) {
      _lastMessage = message;
      _messageCtrl.add(message);
    }

    _handleRelayPayload(data['relay']);
    _mergeAutoPayload(data);

    _handleStatusWaterLevel(data);

    _handleSnapshotValue('temperature', data['temperature'], _temperatureCtrl);
    _handleSnapshotValue('ec_ms', data['ec_ms'] ?? data['ec'], _ecMsCtrl);
    _handleSnapshotValue('ec_us', data['ec_us'], _ecUsCtrl);
    _handleSnapshotValue('ppm', data['ppm'], _ppmCtrl);
    _handleSnapshotValue('do', data['do'], _doCtrl);
    _handleSnapshotValue('tds', data['tds'], _tdsCtrl);
    _handleSnapshotValue('ph', data['ph'] ?? data['pH'], _phCtrl);

    if (data['online'] is bool) {
      final online = data['online'] == true;
      _lastOnline = online;
      _onlineCtrl.add(online);
    } else {
      _evaluateOnline();
    }
  }

  void _handleRelayPayload(dynamic relay) {
    if (relay is! Map) return;
    final next = _emptyRelayStates();
    for (final key in relayKeys) {
      next[key] = relay[key] == true;
    }
    _relayByNode[_nodeKey] = next;
    _relayCtrl.add(Map<String, bool>.unmodifiable(next));
  }

  void _mergeAutoPayload(Map<String, dynamic> data) {
    final auto = data['auto'];
    final hasNestedAuto = auto is Map;
    final hasTopLevelAutoHints =
        data['enabled'] is bool ||
        data['sensor_hold_active'] is bool ||
        data['nft_sensor_warmup_active'] is bool ||
        data['nft_sensor_warmup_remaining'] is num ||
        data['nft_remaining'] is num ||
        data['irrigation_remaining'] is num ||
        data['dosing_remaining'] is num ||
        data['control_ppm'] is num ||
        data['control_ph'] is num;
    if (!hasNestedAuto && !hasTopLevelAutoHints) return;

    final autoSource = hasNestedAuto
        ? Map<String, dynamic>.from(auto)
        : Map<String, dynamic>.from(data);
    final previous = _autoByNode[_nodeKey] ?? const IndoorAutoConfig();
    final parsed = IndoorAutoConfig.fromJson(autoSource).copyWith(
      enabled: autoSource['enabled'] is bool ? autoSource['enabled'] == true : previous.enabled,
      sensorHoldActive: data['sensor_hold_active'] is bool
          ? data['sensor_hold_active'] == true
          : null,
      nftSensorWarmupActive: data['nft_sensor_warmup_active'] is bool
          ? data['nft_sensor_warmup_active'] == true
          : null,
      nftSensorWarmupRemaining:
          (data['nft_sensor_warmup_remaining'] as num?)?.toInt(),
      controlEcUs: (data['control_ec_us'] as num?)?.toDouble(),
      controlEcMs: (data['control_ec_ms'] as num?)?.toDouble(),
      controlPpm: (data['control_ppm'] as num?)?.toDouble(),
      controlTemperature: (data['control_temperature'] as num?)?.toDouble(),
      controlDo: (data['control_do'] as num?)?.toDouble(),
      controlTds: (data['control_tds'] as num?)?.toDouble(),
      controlPh: (data['control_ph'] as num?)?.toDouble(),
    );
    _autoByNode[_nodeKey] = previous.copyWith(
      enabled: autoSource.containsKey('enabled') ? parsed.enabled : null,
      nftIntervalMin: autoSource.containsKey('nft_interval_min')
          ? parsed.nftIntervalMin
          : null,
      nftDurationMin: autoSource.containsKey('nft_duration_min')
          ? parsed.nftDurationMin
          : null,
      irrigationDurationSec:
          autoSource.containsKey('irrigation_duration_sec')
              ? parsed.irrigationDurationSec
              : null,
      irrigationMode: autoSource.containsKey('irrigation_mode')
          ? parsed.irrigationMode
          : null,
      irrigationTimes: autoSource.containsKey('irrigation_times')
          ? parsed.irrigationTimes
          : null,
      targetPpm: autoSource.containsKey('target_ppm') ? parsed.targetPpm : null,
      ppmDeadband: autoSource.containsKey('ppm_deadband')
          ? parsed.ppmDeadband
          : null,
      targetPh: autoSource.containsKey('target_ph') ? parsed.targetPh : null,
      phDeadband: autoSource.containsKey('ph_deadband')
          ? parsed.phDeadband
          : null,
      nutritionDosePulseSec:
          autoSource.containsKey('nutrition_dose_pulse_sec') ||
                  autoSource.containsKey('dose_pulse_sec')
              ? parsed.nutritionDosePulseSec
              : null,
      phDosePulseSec:
          autoSource.containsKey('ph_dose_pulse_sec') ||
                  autoSource.containsKey('dose_pulse_sec')
              ? parsed.phDosePulseSec
              : null,
      nutritionDosingCooldownSec:
          autoSource.containsKey('nutrition_dosing_cooldown_sec') ||
                  autoSource.containsKey('dosing_cooldown_sec')
              ? parsed.nutritionDosingCooldownSec
              : null,
      phDosingCooldownSec:
          autoSource.containsKey('ph_dosing_cooldown_sec') ||
                  autoSource.containsKey('dosing_cooldown_sec')
              ? parsed.phDosingCooldownSec
              : null,
      nftRemaining: autoSource.containsKey('nft_remaining')
          ? parsed.nftRemaining
          : null,
      irrigationRemaining: autoSource.containsKey('irrigation_remaining')
          ? parsed.irrigationRemaining
          : null,
      dosingRemaining: autoSource.containsKey('dosing_remaining')
          ? parsed.dosingRemaining
          : null,
      dosingMode: autoSource.containsKey('dosing_mode') ? parsed.dosingMode : null,
      nutritionCooldownRemaining:
          autoSource.containsKey('nutrition_cooldown_remaining')
              ? parsed.nutritionCooldownRemaining
              : null,
      phCooldownRemaining: autoSource.containsKey('ph_cooldown_remaining')
          ? parsed.phCooldownRemaining
          : null,
      sensorHoldActive: data['sensor_hold_active'] is bool
          ? parsed.sensorHoldActive
          : null,
      nftSensorWarmupActive: data['nft_sensor_warmup_active'] is bool
          ? parsed.nftSensorWarmupActive
          : null,
      nftSensorWarmupRemaining: data['nft_sensor_warmup_remaining'] is num
          ? parsed.nftSensorWarmupRemaining
          : null,
      nftSensorWarmupSec: autoSource.containsKey('nft_sensor_warmup_sec')
          ? parsed.nftSensorWarmupSec
          : null,
      controlEcUs:
          data['control_ec_us'] is num ? parsed.controlEcUs : null,
      controlEcMs:
          data['control_ec_ms'] is num ? parsed.controlEcMs : null,
      controlPpm: data['control_ppm'] is num ? parsed.controlPpm : null,
      controlTemperature: data['control_temperature'] is num
          ? parsed.controlTemperature
          : null,
      controlDo: data['control_do'] is num ? parsed.controlDo : null,
      controlTds: data['control_tds'] is num ? parsed.controlTds : null,
      controlPh: data['control_ph'] is num ? parsed.controlPh : null,
      roTargetLevel: autoSource.containsKey('ro_target_level')
          ? parsed.roTargetLevel
          : null,
      roTargetLabel: autoSource.containsKey('ro_target_label')
          ? parsed.roTargetLabel
          : null,
    );
    _autoCtrl.add(_autoByNode[_nodeKey]!);
  }

  void _handleSnapshotValue(
    String key,
    dynamic raw,
    StreamController<double?> controller,
  ) {
    if (raw is! num) return;
    final value = raw.toDouble();
    _latestByNode.putIfAbsent(_nodeKey, () => <String, double?>{})[key] = value;
    controller.add(value);
  }

  void _handleNumericField(
    String key,
    dynamic raw,
    int timestamp,
    StreamController<double?> controller,
  ) {
    if (raw is! num) return;
    final value = raw.toDouble();
    _latestByNode.putIfAbsent(_nodeKey, () => <String, double?>{})[key] = value;
    final perField = _historyByNode.putIfAbsent(_nodeKey, () => <String, List<IndoorHistoryPoint>>{});
    final history = perField.putIfAbsent(key, () => <IndoorHistoryPoint>[]);
    history.add(IndoorHistoryPoint(timestamp: timestamp, value: value));
    if (history.length > _historyLimit) {
      history.removeRange(0, history.length - _historyLimit);
    }
    controller.add(value);
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

  Stream<T?> _replayNullableStream<T>(
    StreamController<T?> controller,
    T? latest,
  ) async* {
    if (latest != null) yield latest;
    yield* controller.stream;
  }

  Stream<T> _replayStream<T>(
    StreamController<T> controller,
    T latest,
  ) async* {
    yield latest;
    yield* controller.stream;
  }

  Stream<double?> temperatureStream() => _replayNullableStream(_temperatureCtrl, cachedTemperature);
  Stream<double?> ecMsStream() => _replayNullableStream(_ecMsCtrl, cachedEcMs);
  Stream<double?> ecUsStream() => _replayNullableStream(_ecUsCtrl, cachedEcUs);
  Stream<double?> ppmStream() => _replayNullableStream(_ppmCtrl, cachedPpm);
  Stream<double?> doStream() => _replayNullableStream(_doCtrl, cachedDo);
  Stream<double?> tdsStream() => _replayNullableStream(_tdsCtrl, cachedTds);
  Stream<double?> phStream() => _replayNullableStream(_phCtrl, cachedPh);
  Stream<bool> onlineStream() => _replayStream(_onlineCtrl, cachedOnline);
  Stream<String> systemMessageStream() => _replayStream(_messageCtrl, cachedMessage);
  Stream<Map<String, bool>> relayStatesStream() => _replayStream(_relayCtrl, cachedRelayStates);
  Stream<IndoorAutoConfig> autoConfigStream() => _replayStream(_autoCtrl, cachedAutoConfig);
  Stream<IndoorWaterLevelState> waterLevelStream() =>
      _replayStream(_waterLevelCtrl, cachedWaterLevel);

  List<IndoorHistoryPoint> historyFor(String field) {
    final perField = _historyByNode[_nodeKey];
    if (perField == null) return const <IndoorHistoryPoint>[];
    return List<IndoorHistoryPoint>.unmodifiable(perField[field] ?? const <IndoorHistoryPoint>[]);
  }

  Future<void> requestStatus() async {
    final payload = <String, dynamic>{
      'type': 'get_status',
      'value': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (!_mqtt.isConnected) {
      await _mqtt.connect();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _mqtt.publishJson(_topic('command'), payload);
  }

  Future<void> setRelayState(String relayKey, bool on) async {
    final payload = <String, dynamic>{
      'type': 'set_relay',
      'relay': relayKey,
      'value': on,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (!_mqtt.isConnected) {
      await _mqtt.connect();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _mqtt.publishJson(_topic('command'), payload);
  }

  Future<void> setAutoMode(bool enabled) async {
    final payload = <String, dynamic>{
      'type': 'set_auto_mode',
      'value': enabled,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (!_mqtt.isConnected) {
      await _mqtt.connect();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _mqtt.publishJson(_topic('command'), payload);
  }

  Future<void> setAutoConfig({
    int? nftIntervalMinutes,
    int? nftDurationMinutes,
    int? irrigationDurationSeconds,
    String? irrigationMode,
    List<String>? irrigationTimes,
    double? targetPpm,
    double? ppmDeadband,
    double? targetPh,
    double? phDeadband,
    int? nutritionDosePulseSeconds,
    int? phDosePulseSeconds,
    int? nutritionDosingCooldownSeconds,
    int? phDosingCooldownSeconds,
    int? nftSensorWarmupSeconds,
    int? roTargetLevel,
    bool? resetRuntime,
  }) async {
    final value = <String, dynamic>{};
    if (nftIntervalMinutes != null) value['nft_interval_min'] = nftIntervalMinutes;
    if (nftDurationMinutes != null) value['nft_duration_min'] = nftDurationMinutes;
    if (irrigationDurationSeconds != null) value['irrigation_duration_sec'] = irrigationDurationSeconds;
    if (irrigationMode != null) value['irrigation_mode'] = irrigationMode;
    if (irrigationTimes != null) value['irrigation_times'] = irrigationTimes;
    if (targetPpm != null) value['target_ppm'] = targetPpm;
    if (ppmDeadband != null) value['ppm_deadband'] = ppmDeadband;
    if (targetPh != null) value['target_ph'] = targetPh;
    if (phDeadband != null) value['ph_deadband'] = phDeadband;
    if (nutritionDosePulseSeconds != null) {
      value['nutrition_dose_pulse_sec'] = nutritionDosePulseSeconds;
    }
    if (phDosePulseSeconds != null) {
      value['ph_dose_pulse_sec'] = phDosePulseSeconds;
    }
    if (nutritionDosingCooldownSeconds != null) {
      value['nutrition_dosing_cooldown_sec'] = nutritionDosingCooldownSeconds;
    }
    if (phDosingCooldownSeconds != null) {
      value['ph_dosing_cooldown_sec'] = phDosingCooldownSeconds;
    }
    if (nftSensorWarmupSeconds != null) {
      value['nft_sensor_warmup_sec'] = nftSensorWarmupSeconds;
    }
    if (roTargetLevel != null) {
      value['ro_target_level'] = roTargetLevel;
    }
    if (resetRuntime != null) {
      value['reset_runtime'] = resetRuntime;
    }
    if (value.isEmpty) return;

    final payload = <String, dynamic>{
      'type': 'set_auto_config',
      'value': value,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (!_mqtt.isConnected) {
      await _mqtt.connect();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _mqtt.publishJson(_topic('command'), payload);
  }

  Map<String, bool> _emptyRelayStates() {
    return <String, bool>{
      for (final key in relayKeys) key: false,
    };
  }

  void _handleStatusWaterLevel(Map<String, dynamic> data) {
    final raw = data['water_level'];
    final source = raw is Map
        ? Map<String, dynamic>.from(raw)
        : Map<String, dynamic>.from(data);
    final hasWaterLevel = source.containsKey('current') ||
        source.containsKey('current_label') ||
        source.containsKey('low_active') ||
        source.containsKey('mid_active') ||
        source.containsKey('high_active') ||
        source.containsKey('ro_fill_active');
    if (!hasWaterLevel) return;
    final parsed = IndoorWaterLevelState.fromStatusJson(source);
    _waterLevelByNode[_nodeKey] = parsed;
    _waterLevelCtrl.add(parsed);
  }

  void _handleTelemetryWaterLevel(Map<String, dynamic> data) {
    final bool hasWaterLevel =
        data.containsKey('water_level_current') ||
        data.containsKey('water_level_label') ||
        data.containsKey('water_level_low_active') ||
        data.containsKey('water_level_mid_active') ||
        data.containsKey('water_level_high_active') ||
        data.containsKey('ro_fill_active');
    if (!hasWaterLevel) return;
    final parsed = IndoorWaterLevelState.fromTelemetryJson(data);
    _waterLevelByNode[_nodeKey] = parsed;
    _waterLevelCtrl.add(parsed);
  }

  void dispose() {
    _telemetrySub?.cancel();
    _statusSub?.cancel();
    _onlineTimer?.cancel();
    _temperatureCtrl.close();
    _ecMsCtrl.close();
    _ecUsCtrl.close();
    _ppmCtrl.close();
    _doCtrl.close();
    _tdsCtrl.close();
    _phCtrl.close();
    _onlineCtrl.close();
    _relayCtrl.close();
    _autoCtrl.close();
    _waterLevelCtrl.close();
    _messageCtrl.close();
  }
}

class IndoorAutoConfig {
  final bool enabled;
  final int nftIntervalMin;
  final int nftDurationMin;
  final int irrigationDurationSec;
  final String irrigationMode;
  final List<String> irrigationTimes;
  final double targetPpm;
  final double ppmDeadband;
  final double targetPh;
  final double phDeadband;
  final int nutritionDosePulseSec;
  final int phDosePulseSec;
  final int nutritionDosingCooldownSec;
  final int phDosingCooldownSec;
  final int nftRemaining;
  final int irrigationRemaining;
  final int dosingRemaining;
  final int dosingMode;
  final int nutritionCooldownRemaining;
  final int phCooldownRemaining;
  final bool sensorHoldActive;
  final bool nftSensorWarmupActive;
  final int nftSensorWarmupRemaining;
  final int nftSensorWarmupSec;
  final double controlEcUs;
  final double controlEcMs;
  final double controlPpm;
  final double controlTemperature;
  final double controlDo;
  final double controlTds;
  final double controlPh;
  final int roTargetLevel;
  final String roTargetLabel;

  const IndoorAutoConfig({
    this.enabled = true,
    this.nftIntervalMin = 30,
    this.nftDurationMin = 5,
    this.irrigationDurationSec = 120,
    this.irrigationMode = 'schedule',
    this.irrigationTimes = const <String>[],
    this.targetPpm = 900,
    this.ppmDeadband = 30,
    this.targetPh = 6,
    this.phDeadband = 0.15,
    this.nutritionDosePulseSec = 2,
    this.phDosePulseSec = 2,
    this.nutritionDosingCooldownSec = 30,
    this.phDosingCooldownSec = 30,
    this.nftRemaining = 0,
    this.irrigationRemaining = 0,
    this.dosingRemaining = 0,
    this.dosingMode = 0,
    this.nutritionCooldownRemaining = 0,
    this.phCooldownRemaining = 0,
    this.sensorHoldActive = false,
    this.nftSensorWarmupActive = false,
    this.nftSensorWarmupRemaining = 0,
    this.nftSensorWarmupSec = 60,
    this.controlEcUs = 0,
    this.controlEcMs = 0,
    this.controlPpm = 0,
    this.controlTemperature = 0,
    this.controlDo = 0,
    this.controlTds = 0,
    this.controlPh = 0,
    this.roTargetLevel = 2,
    this.roTargetLabel = 'MID',
  });

  factory IndoorAutoConfig.fromJson(Map<String, dynamic> json) {
    return IndoorAutoConfig(
      enabled: json['enabled'] == true,
      nftIntervalMin: (json['nft_interval_min'] as num?)?.toInt() ?? 30,
      nftDurationMin: (json['nft_duration_min'] as num?)?.toInt() ?? 5,
      irrigationDurationSec: (json['irrigation_duration_sec'] as num?)?.toInt() ?? 120,
      irrigationMode: json['irrigation_mode']?.toString() == 'nft'
          ? 'nft'
          : 'schedule',
      irrigationTimes: ((json['irrigation_times'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(),
      targetPpm: (json['target_ppm'] as num?)?.toDouble() ?? 900,
      ppmDeadband: (json['ppm_deadband'] as num?)?.toDouble() ?? 30,
      targetPh: (json['target_ph'] as num?)?.toDouble() ?? 6,
      phDeadband: (json['ph_deadband'] as num?)?.toDouble() ?? 0.15,
      nutritionDosePulseSec:
          (json['nutrition_dose_pulse_sec'] as num?)?.toInt() ??
              (json['dose_pulse_sec'] as num?)?.toInt() ??
              2,
      phDosePulseSec:
          (json['ph_dose_pulse_sec'] as num?)?.toInt() ??
              (json['dose_pulse_sec'] as num?)?.toInt() ??
              2,
      nutritionDosingCooldownSec:
          (json['nutrition_dosing_cooldown_sec'] as num?)?.toInt() ??
              (json['dosing_cooldown_sec'] as num?)?.toInt() ??
              30,
      phDosingCooldownSec:
          (json['ph_dosing_cooldown_sec'] as num?)?.toInt() ??
              (json['dosing_cooldown_sec'] as num?)?.toInt() ??
              30,
      nftRemaining: (json['nft_remaining'] as num?)?.toInt() ?? 0,
      irrigationRemaining: (json['irrigation_remaining'] as num?)?.toInt() ?? 0,
      dosingRemaining: (json['dosing_remaining'] as num?)?.toInt() ?? 0,
      dosingMode: (json['dosing_mode'] as num?)?.toInt() ?? 0,
      nutritionCooldownRemaining:
          (json['nutrition_cooldown_remaining'] as num?)?.toInt() ?? 0,
      phCooldownRemaining:
          (json['ph_cooldown_remaining'] as num?)?.toInt() ?? 0,
      sensorHoldActive: json['sensor_hold_active'] == true,
      nftSensorWarmupActive: json['nft_sensor_warmup_active'] == true,
      nftSensorWarmupRemaining:
          (json['nft_sensor_warmup_remaining'] as num?)?.toInt() ?? 0,
      nftSensorWarmupSec:
          ((json['nft_sensor_warmup_sec'] as num?)?.toInt() ?? 60) >= 60
              ? 60
              : 30,
      controlEcUs: (json['control_ec_us'] as num?)?.toDouble() ?? 0,
      controlEcMs: (json['control_ec_ms'] as num?)?.toDouble() ?? 0,
      controlPpm: (json['control_ppm'] as num?)?.toDouble() ?? 0,
      controlTemperature:
          (json['control_temperature'] as num?)?.toDouble() ?? 0,
      controlDo: (json['control_do'] as num?)?.toDouble() ?? 0,
      controlTds: (json['control_tds'] as num?)?.toDouble() ?? 0,
      controlPh: (json['control_ph'] as num?)?.toDouble() ?? 0,
      roTargetLevel: (json['ro_target_level'] as num?)?.toInt() ?? 2,
      roTargetLabel: json['ro_target_label']?.toString() ?? 'MID',
    );
  }

  IndoorAutoConfig copyWith({
    bool? enabled,
    int? nftIntervalMin,
    int? nftDurationMin,
    int? irrigationDurationSec,
    String? irrigationMode,
    List<String>? irrigationTimes,
    double? targetPpm,
    double? ppmDeadband,
    double? targetPh,
    double? phDeadband,
    int? nutritionDosePulseSec,
    int? phDosePulseSec,
    int? nutritionDosingCooldownSec,
    int? phDosingCooldownSec,
    int? nftRemaining,
    int? irrigationRemaining,
    int? dosingRemaining,
    int? dosingMode,
    int? nutritionCooldownRemaining,
    int? phCooldownRemaining,
    bool? sensorHoldActive,
    bool? nftSensorWarmupActive,
    int? nftSensorWarmupRemaining,
    int? nftSensorWarmupSec,
    double? controlEcUs,
    double? controlEcMs,
    double? controlPpm,
    double? controlTemperature,
    double? controlDo,
    double? controlTds,
    double? controlPh,
    int? roTargetLevel,
    String? roTargetLabel,
  }) {
    return IndoorAutoConfig(
      enabled: enabled ?? this.enabled,
      nftIntervalMin: nftIntervalMin ?? this.nftIntervalMin,
      nftDurationMin: nftDurationMin ?? this.nftDurationMin,
      irrigationDurationSec:
          irrigationDurationSec ?? this.irrigationDurationSec,
      irrigationMode: irrigationMode ?? this.irrigationMode,
      irrigationTimes: irrigationTimes ?? this.irrigationTimes,
      targetPpm: targetPpm ?? this.targetPpm,
      ppmDeadband: ppmDeadband ?? this.ppmDeadband,
      targetPh: targetPh ?? this.targetPh,
      phDeadband: phDeadband ?? this.phDeadband,
      nutritionDosePulseSec:
          nutritionDosePulseSec ?? this.nutritionDosePulseSec,
      phDosePulseSec: phDosePulseSec ?? this.phDosePulseSec,
      nutritionDosingCooldownSec:
          nutritionDosingCooldownSec ?? this.nutritionDosingCooldownSec,
      phDosingCooldownSec:
          phDosingCooldownSec ?? this.phDosingCooldownSec,
      nftRemaining: nftRemaining ?? this.nftRemaining,
      irrigationRemaining: irrigationRemaining ?? this.irrigationRemaining,
      dosingRemaining: dosingRemaining ?? this.dosingRemaining,
      dosingMode: dosingMode ?? this.dosingMode,
      nutritionCooldownRemaining:
          nutritionCooldownRemaining ?? this.nutritionCooldownRemaining,
      phCooldownRemaining: phCooldownRemaining ?? this.phCooldownRemaining,
      sensorHoldActive: sensorHoldActive ?? this.sensorHoldActive,
      nftSensorWarmupActive:
          nftSensorWarmupActive ?? this.nftSensorWarmupActive,
      nftSensorWarmupRemaining:
          nftSensorWarmupRemaining ?? this.nftSensorWarmupRemaining,
      nftSensorWarmupSec: nftSensorWarmupSec ?? this.nftSensorWarmupSec,
      controlEcUs: controlEcUs ?? this.controlEcUs,
      controlEcMs: controlEcMs ?? this.controlEcMs,
      controlPpm: controlPpm ?? this.controlPpm,
      controlTemperature: controlTemperature ?? this.controlTemperature,
      controlDo: controlDo ?? this.controlDo,
      controlTds: controlTds ?? this.controlTds,
      controlPh: controlPh ?? this.controlPh,
      roTargetLevel: roTargetLevel ?? this.roTargetLevel,
      roTargetLabel: roTargetLabel ?? this.roTargetLabel,
    );
  }
}

class IndoorWaterLevelState {
  final bool lowActive;
  final bool midActive;
  final bool highActive;
  final int currentLevel;
  final String currentLabel;
  final bool roFillActive;

  const IndoorWaterLevelState({
    this.lowActive = false,
    this.midActive = false,
    this.highActive = false,
    this.currentLevel = 0,
    this.currentLabel = 'EMPTY',
    this.roFillActive = false,
  });

  factory IndoorWaterLevelState.fromStatusJson(Map<String, dynamic> json) {
    return IndoorWaterLevelState(
      lowActive: json['low_active'] == true,
      midActive: json['mid_active'] == true,
      highActive: json['high_active'] == true,
      currentLevel: (json['current'] as num?)?.toInt() ?? 0,
      currentLabel: json['current_label']?.toString() ?? 'EMPTY',
      roFillActive: json['ro_fill_active'] == true,
    );
  }

  factory IndoorWaterLevelState.fromTelemetryJson(Map<String, dynamic> json) {
    return IndoorWaterLevelState(
      lowActive: json['water_level_low_active'] == true,
      midActive: json['water_level_mid_active'] == true,
      highActive: json['water_level_high_active'] == true,
      currentLevel: (json['water_level_current'] as num?)?.toInt() ?? 0,
      currentLabel: json['water_level_label']?.toString() ?? 'EMPTY',
      roFillActive: json['ro_fill_active'] == true,
    );
  }
}

class IndoorHistoryPoint {
  final int timestamp;
  final double value;

  const IndoorHistoryPoint({
    required this.timestamp,
    required this.value,
  });
}
