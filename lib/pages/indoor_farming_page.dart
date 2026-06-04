import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../services/activity_logger_service.dart';
import '../services/indoor_farming_access_api_service.dart';
import '../services/indoor_farming_mqtt_service.dart';
import '../services/mongo_history_service.dart';
import '../widgets/portal_scaffold.dart';

class IndoorFarmingPage extends StatefulWidget {
  const IndoorFarmingPage({super.key});

  @override
  State<IndoorFarmingPage> createState() => _IndoorFarmingPageState();
}

class _IndoorFarmingPageState extends State<IndoorFarmingPage> {
  late final IndoorFarmingMqttService _service;
  late final IndoorFarmingAccessApiService _accessService;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _historyReloadTimer;
  Timer? _accessCountdownTimer;
  Timer? _statusRefreshTimer;
  Timer? _runtimeTicker;

  double? _temperature;
  double? _ecMs;
  double? _ecUs;
  double? _ppm;
  double? _dissolvedOxygen;
  double? _tds;
  double? _ph;
  bool _online = false;
  String _message = 'Menunggu data indoor farming...';
  String _selectedMetric = 'temperature';
  String _selectedRange = '15m';
  bool _chartLoading = false;
  String? _chartError;
  DateTime? _chartLoadedAt;
  DateTime? _lastUpdatedAt;
  DateTime? _autoStatusReceivedAt;
  DateTime _runtimeNow = DateTime.now();
  IndoorAutoConfig _autoConfig = const IndoorAutoConfig();
  IndoorAutoConfig _backendAutoConfig = const IndoorAutoConfig();
  bool _hasBackendAutoConfig = false;
  IndoorWaterLevelState _waterLevel = const IndoorWaterLevelState();
  IndoorFarmingControlAccess _controlAccess =
      IndoorFarmingControlAccess.fallback();
  bool _controlAccessLoading = true;
  bool _unlockSubmitting = false;
  String? _controlAccessError;
  Map<String, bool> _relayStates = <String, bool>{
    for (final key in IndoorFarmingMqttService.relayKeys) key: false,
  };
  String _manualControlMode = 'direct';
  final Map<String, _ManualTimerConfig> _manualTimerConfig = <String, _ManualTimerConfig>{
    for (final key in IndoorFarmingMqttService.relayKeys)
      key: const _ManualTimerConfig(),
  };
  final Map<String, DateTime?> _manualRelayDeadlines = <String, DateTime?>{
    for (final key in IndoorFarmingMqttService.relayKeys) key: null,
  };
  final Map<String, List<_MongoChartPoint>> _mongoHistory = <String, List<_MongoChartPoint>>{
    for (final key in _metricMeta.keys) key: <_MongoChartPoint>[],
  };

  static const List<_RelayMeta> _relayMetas = <_RelayMeta>[
    _RelayMeta(key: 'do1', title: 'Nutrisi A', subtitle: 'Pompa dosis A'),
    _RelayMeta(key: 'do2', title: 'Nutrisi B', subtitle: 'Pompa dosis B'),
    _RelayMeta(key: 'do3', title: 'pH UP', subtitle: 'Koreksi pH naik'),
    _RelayMeta(key: 'do4', title: 'pH DOWN', subtitle: 'Koreksi pH turun'),
    _RelayMeta(key: 'do5', title: 'Pompa NFT', subtitle: 'Sirkulasi NFT'),
    _RelayMeta(key: 'do6', title: 'Pompa Irigasi', subtitle: 'Siklus irigasi'),
    _RelayMeta(key: 'do7', title: 'Pompa RO', subtitle: 'Air baku'),
  ];

  static const Map<String, _IndoorMetricMeta> _metricMeta = {
    'temperature': _IndoorMetricMeta(
      label: 'Suhu',
      unit: 'C',
      color: Color(0xFFFFB74D),
      decimals: 2,
    ),
    'ec_us': _IndoorMetricMeta(
      label: 'EC uS/cm',
      unit: 'uS/cm',
      color: Color(0xFF64B5F6),
      decimals: 2,
    ),
    'ec_ms': _IndoorMetricMeta(
      label: 'EC mS/cm',
      unit: 'mS/cm',
      color: Color(0xFF26A69A),
      decimals: 3,
    ),
    'ppm': _IndoorMetricMeta(
      label: 'PPM',
      unit: 'ppm',
      color: Color(0xFFBA68C8),
      decimals: 2,
    ),
    'do': _IndoorMetricMeta(
      label: 'Oksigen',
      unit: 'mg/L',
      color: Color(0xFF81C784),
      decimals: 2,
    ),
    'tds': _IndoorMetricMeta(
      label: 'TDS',
      unit: 'ppm',
      color: Color(0xFF4DD0E1),
      decimals: 2,
    ),
    'ph': _IndoorMetricMeta(
      label: 'pH',
      unit: 'pH',
      color: Color(0xFFEF5350),
      decimals: 3,
    ),
  };

  @override
  void initState() {
    super.initState();
    _service = IndoorFarmingMqttService();
    _accessService = IndoorFarmingAccessApiService();
    _temperature = _service.cachedTemperature;
    _ecMs = _service.cachedEcMs;
    _ecUs = _service.cachedEcUs;
    _ppm = _service.cachedPpm;
    _dissolvedOxygen = _service.cachedDo;
    _tds = _service.cachedTds;
    _ph = _service.cachedPh;
    _online = _service.cachedOnline;
    _message = _service.cachedMessage;
    _autoConfig = _service.cachedAutoConfig;
    _waterLevel = _service.cachedWaterLevel;
    _relayStates = Map<String, bool>.from(_service.cachedRelayStates);

    ActivityLoggerService.log(
      action: 'screen.open',
      module: 'indoor_farming',
      description: 'Membuka halaman indoor farming',
      deviceId: IndoorFarmingMqttService.defaultDeviceId,
    );

    _subscriptions.addAll([
      _service.temperatureStream().listen((value) {
        _applyValue(() => _temperature = value);
        _appendLiveChartSample('temperature', value);
      }),
      _service.ecMsStream().listen((value) {
        _applyValue(() => _ecMs = value);
        _appendLiveChartSample('ec_ms', value);
      }),
      _service.ecUsStream().listen((value) {
        _applyValue(() => _ecUs = value);
        _appendLiveChartSample('ec_us', value);
      }),
      _service.ppmStream().listen((value) {
        _applyValue(() => _ppm = value);
        _appendLiveChartSample('ppm', value);
      }),
      _service.doStream().listen((value) {
        _applyValue(() => _dissolvedOxygen = value);
        _appendLiveChartSample('do', value);
      }),
      _service.tdsStream().listen((value) {
        _applyValue(() => _tds = value);
        _appendLiveChartSample('tds', value);
      }),
      _service.phStream().listen((value) {
        _applyValue(() => _ph = value);
        _appendLiveChartSample('ph', value);
      }),
      _service.onlineStream().listen((value) => _applyValue(() => _online = value)),
      _service.systemMessageStream().listen((value) => _applyValue(() => _message = value)),
      _service.relayStatesStream().listen((value) => _applyValue(() {
        _relayStates = Map<String, bool>.from(value);
        _syncManualRelayCountdownState();
      })),
      _service.autoConfigStream().listen((value) => _applyValue(() {
        final base = _hasBackendAutoConfig ? _backendAutoConfig : _autoConfig;
        _autoConfig = _mergeRuntimeState(base, value);
        _autoStatusReceivedAt = DateTime.now();
        _syncManualRelayCountdownState();
      })),
      _service.waterLevelStream().listen((value) => _applyValue(() => _waterLevel = value)),
    ]);

    unawaited(_service.requestStatus());
    unawaited(_loadControlAccess());
    unawaited(_loadBackendAutoConfig());
    unawaited(_loadMongoChartHistory());
    _historyReloadTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        unawaited(_loadMongoChartHistory());
        unawaited(_loadControlAccess());
        unawaited(_loadBackendAutoConfig());
      },
    );
    _syncAccessCountdownTimer();
    _startStatusSyncTimers();
  }

  void _applyValue(VoidCallback mutate) {
    if (!mounted) return;
    setState(() {
      mutate();
      _lastUpdatedAt = DateTime.now();
    });
  }

  void _appendLiveChartSample(String metricKey, double? value) {
    if (value == null) return;
    final target = _mongoHistory[metricKey];
    if (target == null) return;

    final now = DateTime.now();
    final sample = _MongoChartPoint(at: now, value: value);

    if (target.isNotEmpty) {
      final last = target.last;
      if (now.difference(last.at).inMilliseconds < 900) {
        target[target.length - 1] = sample;
      } else {
        target.add(sample);
      }
    } else {
      target.add(sample);
    }

    _trimChartToActiveRange(target);
    if (!mounted) return;
    setState(() {
      _chartLoadedAt = now;
    });
  }

  Future<void> _loadControlAccess({bool showLoading = false}) async {
    if (showLoading && mounted) {
      setState(() {
        _controlAccessLoading = true;
        _controlAccessError = null;
      });
    }

    try {
      final snapshot = await _accessService.fetchAccessSnapshot();
      if (!mounted) return;
      setState(() {
        _controlAccess = snapshot.access;
        if (snapshot.config != null) {
          _backendAutoConfig = snapshot.config!;
          _hasBackendAutoConfig = true;
          _autoConfig = _mergeRuntimeState(_backendAutoConfig, _autoConfig);
        }
        _controlAccessLoading = false;
        _controlAccessError = null;
      });
      _syncAccessCountdownTimer();
    } on IndoorFarmingAccessApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _controlAccessLoading = false;
        _controlAccessError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _controlAccessLoading = false;
        _controlAccessError = 'Gagal membaca akses indoor farming.';
      });
    }
  }

  Future<bool> _promptControlPin({String target = 'config_control'}) async {
    final controller = TextEditingController();
    String? errorText;
    var unlocked = false;
    final targetLabel = switch (target) {
      'config' => 'konfigurasi',
      'control' => 'kontrol',
      _ => 'konfigurasi dan kontrol',
    };

    await showDialog<void>(
      context: context,
      barrierDismissible: !_unlockSubmitting,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> submit() async {
              final pin = controller.text.trim();
              if (pin.isEmpty) {
                setModalState(() {
                  errorText = 'Masukkan PIN indoor farming terlebih dahulu.';
                });
                return;
              }

              setModalState(() {
                errorText = null;
              });
              if (mounted) {
                setState(() {
                  _unlockSubmitting = true;
                  _controlAccessError = null;
                });
              }

              try {
                final snapshot = await _accessService.unlockControlsSnapshot(
                  pin,
                  target: target,
                );
                if (!mounted) return;
                setState(() {
                  _controlAccess = snapshot.access;
                  if (snapshot.config != null) {
                    _backendAutoConfig = snapshot.config!;
                    _hasBackendAutoConfig = true;
                    _autoConfig = _mergeRuntimeState(_backendAutoConfig, _autoConfig);
                  }
                  _unlockSubmitting = false;
                  _controlAccessError = null;
                });
                _syncAccessCountdownTimer();
                Navigator.of(dialogContext).pop();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Akses indoor farming berhasil dibuka.'),
                  ),
                );
                unlocked = true;
              } on IndoorFarmingAccessApiException catch (e) {
                if (!mounted) return;
                setState(() {
                  _unlockSubmitting = false;
                  _controlAccessError = e.message;
                });
                setModalState(() {
                  errorText = e.message;
                });
              } catch (_) {
                if (!mounted) return;
                setState(() {
                  _unlockSubmitting = false;
                  _controlAccessError =
                      'Gagal memverifikasi PIN indoor farming.';
                });
                setModalState(() {
                  errorText = 'Gagal memverifikasi PIN indoor farming.';
                });
              }
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF10311E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text(
                'Masukkan PIN Indoor Farming',
                style: TextStyle(
                  color: Color(0xFFF1F8E9),
                  fontWeight: FontWeight.w800,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Masukkan PIN untuk membuka akses $targetLabel di mobile.',
                    style: TextStyle(
                      color: Color(0xFFC8E6C9),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    enabled: !_unlockSubmitting,
                    style: const TextStyle(color: Color(0xFFF1F8E9)),
                    decoration: InputDecoration(
                      labelText: 'PIN',
                      counterText: '',
                      labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
                      errorText: errorText,
                      filled: true,
                      fillColor: const Color(0x331C5A2A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onSubmitted: (_) => unawaited(submit()),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: _unlockSubmitting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Batal'),
                ),
                FilledButton(
                  onPressed: _unlockSubmitting ? null : () => unawaited(submit()),
                  child: Text(_unlockSubmitting ? 'Memeriksa...' : 'Buka Akses'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
    return unlocked;
  }

  Duration? _currentUnlockRemaining() {
    final expiresAt = _controlAccess.unlockExpiresAt;
    if (expiresAt == null) return null;
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds <= 0) {
      return Duration.zero;
    }
    return remaining;
  }

  String _fmtCountdown(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 864000);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _syncAccessCountdownTimer() {
    _accessCountdownTimer?.cancel();
    final remaining = _currentUnlockRemaining();
    if (remaining == null || remaining == Duration.zero) {
      if (_controlAccess.unlockExpiresAt != null &&
          _controlAccess.requiresPin &&
          !_controlAccess.bypassGranted &&
          _controlAccess.canManageControls &&
          mounted) {
        setState(() {
          _controlAccess = IndoorFarmingControlAccess(
            role: _controlAccess.role,
            requiresPin: _controlAccess.requiresPin,
            canManageControls: false,
            bypassGranted: _controlAccess.bypassGranted,
            unlockDurationMinutes: _controlAccess.unlockDurationMinutes,
            unlockExpiresAt: null,
          );
        });
      }
      return;
    }

    _accessCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final nextRemaining = _currentUnlockRemaining();
      if (nextRemaining == null || nextRemaining == Duration.zero) {
        _accessCountdownTimer?.cancel();
        setState(() {
          _controlAccess = IndoorFarmingControlAccess(
            role: _controlAccess.role,
            requiresPin: _controlAccess.requiresPin,
            canManageControls: false,
            bypassGranted: _controlAccess.bypassGranted,
            unlockDurationMinutes: _controlAccess.unlockDurationMinutes,
            unlockExpiresAt: null,
          );
        });
        return;
      }

      setState(() {});
    });
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _historyReloadTimer?.cancel();
    _accessCountdownTimer?.cancel();
    _statusRefreshTimer?.cancel();
    _runtimeTicker?.cancel();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PortalScaffold(
      badge: 'INDOOR FARMING',
      title: 'Indoor Farming Sensor',
      subtitle: 'Monitoring realtime nutrisi, runtime otomatis, dan tandon RO',
      maxWidth: 880,
      actions: [
        PortalActionButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onTap: () {
            unawaited(_service.requestStatus());
            unawaited(_loadControlAccess(showLoading: true));
            unawaited(_loadBackendAutoConfig());
            unawaited(_loadMongoChartHistory(force: true));
          },
        ),
        PortalActionButton(
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onTap: () => Navigator.pop(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          const SizedBox(height: 14),
          _buildMetricGrid(),
          const SizedBox(height: 16),
          _buildWaterTankPanel(),
          const SizedBox(height: 16),
          _buildChartPanel(),
          const SizedBox(height: 16),
          _buildMonitoringPanel(),
          const SizedBox(height: 16),
          _buildControlAccessPanel(),
          const SizedBox(height: 16),
          _buildRelayStatusPanel(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _headerPill('Device: ${IndoorFarmingMqttService.defaultDeviceId}'),
        _headerPill('Area: ${IndoorFarmingMqttService.defaultArea}'),
        _headerPill(
          _online ? 'Device Online' : 'Device Offline',
          color: _online ? const Color(0x442E7D32) : const Color(0x66C62828),
        ),
        _headerPill(
          _controlAccess.canManageControls ? 'Kontrol Terbuka' : 'Monitoring Only',
          color: _controlAccess.canManageControls
              ? const Color(0x4443A047)
              : const Color(0x66EF6C00),
        ),
        _headerPill(_lastUpdatedAt == null
            ? 'Menunggu data'
            : 'Update: ${_fmtDateTime(_lastUpdatedAt!)}'),
      ],
    );
  }

  Widget _headerPill(String text, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color ?? const Color(0x441C5A2A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFEAF8EF),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildMetricGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 760;
        final crossAxisCount = isWide ? 3 : 2;
        final isCompactPhone = constraints.maxWidth < 420;
        final cards = <Widget>[
          _metricCard('EC', _ecUs, 'uS/cm', note: '${_fmt(_ecMs, 3)} mS/cm', color: _metricMeta['ec_us']!.color),
          _metricCard('PPM', _ppm, 'ppm', note: 'Konversi realtime', color: _metricMeta['ppm']!.color),
          _metricCard('Suhu', _temperature, 'C', note: 'Suhu larutan', color: _metricMeta['temperature']!.color),
          _metricCard('Oksigen', _dissolvedOxygen, 'mg/L', note: 'Oksigen terlarut', color: _metricMeta['do']!.color),
          _metricCard('TDS', _tds, 'ppm', note: 'Padatan terlarut', color: _metricMeta['tds']!.color),
          _metricCard('pH', _ph, 'pH', note: 'Keasaman larutan', color: _metricMeta['ph']!.color),
          _metricCard('Status', _online ? 1 : 0, '', note: _message, asStatus: true, color: _online ? const Color(0xFF66BB6A) : const Color(0xFFEF5350)),
        ];

        return GridView.count(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          childAspectRatio: isWide ? 1.08 : (isCompactPhone ? 0.78 : 0.84),
          children: cards,
        );
      },
    );
  }

  Future<bool> _ensureAccessUnlocked(String target) async {
    if (_controlAccess.canManageControls) {
      return true;
    }

    final canUnlock =
        _controlAccess.requiresPin && !_controlAccess.bypassGranted;
    if (!canUnlock) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Akun ini hanya memiliki akses monitoring indoor farming.',
          ),
        ),
      );
      return false;
    }

    return _promptControlPin(target: target);
  }

  Future<void> _runWithControlAccess({
    required String target,
    required Future<void> Function() action,
  }) async {
    final unlocked = await _ensureAccessUnlocked(target);
    if (!mounted || !unlocked) return;
    await action();
  }

  void _startStatusSyncTimers() {
    _statusRefreshTimer?.cancel();
    _statusRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_service.requestStatus());
    });

    _runtimeTicker?.cancel();
    _runtimeTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final expiredRelays = <String>[];
      for (final entry in _manualRelayDeadlines.entries) {
        final deadline = entry.value;
        if (deadline == null) continue;
        if (_autoConfig.enabled || _relayStates[entry.key] != true) {
          _manualRelayDeadlines[entry.key] = null;
          continue;
        }
        if (!deadline.isAfter(now)) {
          _manualRelayDeadlines[entry.key] = null;
          expiredRelays.add(entry.key);
        }
      }

      if (!mounted) return;
      setState(() {
        _runtimeNow = now;
      });

      for (final relayKey in expiredRelays) {
        unawaited(_expireManualRelay(relayKey));
      }
    });
  }

  void _syncManualRelayCountdownState() {
    if (_autoConfig.enabled) {
      for (final key in _manualRelayDeadlines.keys) {
        _manualRelayDeadlines[key] = null;
      }
      return;
    }

    for (final entry in _relayStates.entries) {
      if (entry.value != true) {
        _manualRelayDeadlines[entry.key] = null;
      }
    }
  }

  int _remainingFromStatus(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final receivedAt = _autoStatusReceivedAt;
    if (safe == 0 || receivedAt == null) return safe;
    final elapsed = _runtimeNow.difference(receivedAt).inSeconds;
    if (elapsed <= 0) return safe;
    return math.max(0, safe - elapsed);
  }

  int get _displayNftRemaining => _remainingFromStatus(_autoConfig.nftRemaining);

  int get _displayIrrigationRemaining =>
      _remainingFromStatus(_autoConfig.irrigationRemaining);

  int get _displayDosingRemaining => _remainingFromStatus(_autoConfig.dosingRemaining);

  int get _displayNutritionCooldownRemaining =>
      _remainingFromStatus(_autoConfig.nutritionCooldownRemaining);

  int get _displayPhCooldownRemaining =>
      _remainingFromStatus(_autoConfig.phCooldownRemaining);

  int get _displayWarmupRemaining =>
      _remainingFromStatus(_autoConfig.nftSensorWarmupRemaining);

  Future<void> _loadBackendAutoConfig() async {
    try {
      final config = await _accessService.fetchConfig();
      if (!mounted) return;
      _applyValue(() {
        _backendAutoConfig = config;
        _hasBackendAutoConfig = true;
        _autoConfig = _mergeRuntimeState(config, _autoConfig);
      });
    } catch (_) {
      // Keep live MQTT state when backend config can't be reached.
    }
  }

  IndoorAutoConfig _mergeRuntimeState(
    IndoorAutoConfig base,
    IndoorAutoConfig runtime,
  ) {
    return base.copyWith(
      enabled: runtime.enabled,
      nftRemaining: runtime.nftRemaining,
      irrigationRemaining: runtime.irrigationRemaining,
      dosingRemaining: runtime.dosingRemaining,
      dosingMode: runtime.dosingMode,
      nutritionCooldownRemaining: runtime.nutritionCooldownRemaining,
      phCooldownRemaining: runtime.phCooldownRemaining,
      sensorHoldActive: runtime.sensorHoldActive,
      nftSensorWarmupActive: runtime.nftSensorWarmupActive,
      nftSensorWarmupRemaining: runtime.nftSensorWarmupRemaining,
      controlEcUs: runtime.controlEcUs,
      controlEcMs: runtime.controlEcMs,
      controlPpm: runtime.controlPpm,
      controlTemperature: runtime.controlTemperature,
      controlDo: runtime.controlDo,
      controlTds: runtime.controlTds,
      controlPh: runtime.controlPh,
    );
  }

  Duration? _manualRelayRemaining(String relayKey) {
    final deadline = _manualRelayDeadlines[relayKey];
    if (deadline == null) return null;
    final remaining = deadline.difference(_runtimeNow);
    if (remaining.inMilliseconds <= 0) return Duration.zero;
    return remaining;
  }

  void _setManualControlMode(String mode) {
    if (_manualControlMode == mode || (mode != 'direct' && mode != 'timer')) {
      return;
    }
    setState(() {
      _manualControlMode = mode;
    });
  }

  Widget _metricCard(
    String label,
    double? value,
    String unit, {
    required String note,
    required Color color,
    bool asStatus = false,
  }) {
    final display = asStatus ? (_online ? 'ON' : 'OFF') : _fmt(value, _metricDecimals(label));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF134722), Color(0xFF0C3418)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _metricIcon(label),
                  color: color,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFCAE8CC),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, valueConstraints) {
              final compact = valueConstraints.maxWidth < 170;
              return Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 6,
                runSpacing: 2,
                children: [
                  Text(
                    display,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                      color: const Color(0xFFF1F8E9),
                      fontWeight: FontWeight.w800,
                      fontSize: compact ? 25 : 28,
                      height: 1,
                    ),
                  ),
                  if (!asStatus && unit.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        unit,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFFC8E6C9),
                          fontWeight: FontWeight.w600,
                          fontSize: compact ? 13 : 14,
                          height: 1.1,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          Text(
            note,
            maxLines: 3,
            overflow: TextOverflow.fade,
            style: const TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildChartPanel() {
    final meta = _metricMeta[_selectedMetric]!;
    final history = _mongoHistory[_selectedMetric] ?? const <_MongoChartPoint>[];
    final spots = history
        .map((point) => FlSpot(point.at.millisecondsSinceEpoch.toDouble(), point.value))
        .toList();
    final selectedRangeMeta = MongoHistoryService.rangeOptions[_selectedRange] ??
        MongoHistoryService.rangeOptions['15m']!;
    final loadingText = _chartLoading
        ? 'Memuat histori MongoDB ${selectedRangeMeta.label}...'
        : (_chartLoadedAt == null
            ? 'Histori MongoDB belum dimuat.'
            : 'Histori MongoDB ${selectedRangeMeta.label} | Update ${_fmtDateTime(_chartLoadedAt!)}');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x55113322),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Grafik MongoDB',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            loadingText,
            style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _metricMeta.entries.map((entry) {
              final active = entry.key == _selectedMetric;
              return ChoiceChip(
                label: Text(entry.value.label),
                selected: active,
                selectedColor: const Color(0xFF2E7D32),
                backgroundColor: const Color(0x331A4A28),
                side: const BorderSide(color: Color(0x55FFFFFF)),
                labelStyle: TextStyle(
                  color: active ? Colors.white : const Color(0xFFEAF8EF),
                  fontWeight: FontWeight.w700,
                ),
                onSelected: (_) {
                  if (_selectedMetric == entry.key) return;
                  setState(() => _selectedMetric = entry.key);
                  unawaited(_loadMongoChartHistory(force: true));
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: MongoHistoryService.rangeOptions.entries.map((entry) {
              final active = entry.key == _selectedRange;
              return ChoiceChip(
                label: Text(entry.value.label),
                selected: active,
                selectedColor: const Color(0xFF1F7A35),
                backgroundColor: const Color(0x331A4A28),
                side: const BorderSide(color: Color(0x55FFFFFF)),
                labelStyle: TextStyle(
                  color: active ? Colors.white : const Color(0xFFEAF8EF),
                  fontWeight: FontWeight.w700,
                ),
                onSelected: (_) {
                  if (_selectedRange == entry.key) return;
                  setState(() {
                    _selectedRange = entry.key;
                  });
                  unawaited(_loadMongoChartHistory(force: true));
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 240,
            child: _chartLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF9CCC65)),
                  )
                : _chartError != null
                    ? Center(
                        child: Text(
                          _chartError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFFFCDD2),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : spots.isEmpty
                ? Center(
                    child: Text(
                      'Belum ada data MongoDB untuk ${meta.label} pada ${selectedRangeMeta.label}.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFC8E6C9),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      minX: _chartAxisRange(spots).$1,
                      maxX: _chartAxisRange(spots).$2,
                      minY: _minY(spots),
                      maxY: _maxY(spots),
                      lineTouchData: LineTouchData(
                        enabled: true,
                        handleBuiltInTouches: true,
                        touchTooltipData: LineTouchTooltipData(
                          tooltipRoundedRadius: 12,
                          tooltipPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          tooltipMargin: 10,
                          tooltipBgColor: const Color(0xCC29434E),
                          fitInsideHorizontally: true,
                          fitInsideVertically: true,
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              final at = DateTime.fromMillisecondsSinceEpoch(
                                spot.x.round(),
                              ).toLocal();
                              return LineTooltipItem(
                                '${meta.label}\n${_fmt(spot.y, meta.decimals)} ${meta.unit}\n${_fmtDateTime(at)}',
                                TextStyle(
                                  color: meta.color,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                  height: 1.35,
                                ),
                              );
                            }).toList();
                          },
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        horizontalInterval: _yInterval(spots),
                        verticalInterval: _xIntervalForTime(spots),
                        getDrawingHorizontalLine: (_) => const FlLine(
                          color: Color(0x223D6847),
                          strokeWidth: 1,
                        ),
                        getDrawingVerticalLine: (_) => const FlLine(
                          color: Color(0x143D6847),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 42,
                            interval: _yInterval(spots),
                            getTitlesWidget: (value, _) => Text(
                              value.toStringAsFixed(meta.decimals > 2 ? 2 : 1),
                              style: const TextStyle(
                                color: Color(0xFFC8E6C9),
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 24,
                            interval: _xIntervalForTime(spots),
                            getTitlesWidget: (value, meta) {
                              if (!_shouldShowMongoXAxisLabel(value, meta, spots)) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                _xToMongoLabel(value),
                                style: const TextStyle(
                                  color: Color(0xFFC8E6C9),
                                  fontSize: 9,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: const Border(
                          left: BorderSide(color: Color(0x33FFFFFF)),
                          bottom: BorderSide(color: Color(0x33FFFFFF)),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: false,
                          color: meta.color,
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              colors: [
                                meta.color.withOpacity(0.28),
                                meta.color.withOpacity(0.02),
                              ],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadMongoChartHistory({bool force = false}) async {
    if (_chartLoading && !force) return;
    if (!mounted) return;

    final requestedMetric = _selectedMetric;

    setState(() {
      _chartLoading = true;
      _chartError = null;
    });

    try {
      final rows = await MongoHistoryService.fetchRows(
        deviceId: IndoorFarmingMqttService.defaultDeviceId,
        measurement: 'indoor_farming_sensor',
        fields: <String>[requestedMetric],
        rangeKey: _selectedRange,
      );

      final nextPoints = <_MongoChartPoint>[];

      for (final row in rows) {
        final at = _parseMongoRowTime(row);
        if (at == null) continue;
        final raw = row[requestedMetric];
        if (raw is num) {
          nextPoints.add(_MongoChartPoint(at: at, value: raw.toDouble()));
        }
      }

      nextPoints.sort((a, b) => a.at.compareTo(b.at));
      _trimChartToActiveRange(nextPoints);

      if (!mounted) return;
      setState(() {
        _mongoHistory[requestedMetric] = nextPoints;
        _chartLoadedAt = DateTime.now();
      });
    } on MongoHistoryException catch (error) {
      if (!mounted) return;
      setState(() {
        _chartError = error.message;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _chartError = 'Permintaan histori MongoDB timeout. Coba refresh lagi.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _chartError = 'Histori MongoDB indoor farming gagal dimuat.';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _chartLoading = false;
      });
    }
  }

  DateTime? _parseMongoRowTime(Map<String, dynamic> row) {
    final rawTimestamp = row['timestamp'];
    if (rawTimestamp is num) {
      return DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt() * 1000).toLocal();
    }

    final rawTime = row['time'] ?? row['recorded_at'] ?? row['created_at'];
    if (rawTime == null) return null;
    return DateTime.tryParse(rawTime.toString())?.toLocal();
  }

  void _trimChartToActiveRange(List<_MongoChartPoint> target) {
    if (target.isEmpty) return;
    final option = MongoHistoryService.rangeOptions[_selectedRange] ??
        MongoHistoryService.rangeOptions['15m']!;
    final cutoff = DateTime.now().subtract(Duration(minutes: option.minutes));
    target.removeWhere((sample) => sample.at.isBefore(cutoff));
    target.sort((a, b) => a.at.compareTo(b.at));
  }

  Widget _buildMonitoringPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x44102D1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Monitoring Operasional',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 12),
          _summaryRow('EC (uS/cm)', '${_fmt(_ecUs, 2)} uS/cm'),
          _summaryRow('EC (mS/cm)', '${_fmt(_ecMs, 3)} mS/cm'),
          _summaryRow('PPM', '${_fmt(_ppm, 2)} ppm'),
          _summaryRow('Oksigen', '${_fmt(_dissolvedOxygen, 2)} mg/L'),
          _summaryRow('Suhu', '${_fmt(_temperature, 2)} C'),
          _summaryRow('TDS', '${_fmt(_tds, 2)} ppm'),
          _summaryRow('pH', '${_fmt(_ph, 3)} pH'),
          _summaryRow('Level Air', _waterLevel.currentLabel),
          _summaryRow('Pompa RO', _waterLevel.roFillActive ? 'ON (mengisi)' : 'OFF'),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xAA113021),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x44FFFFFF)),
            ),
            child: const Text(
              'Topik data: buncop/indoor_farming/indoor_farming_sensor/telemetry',
              style: TextStyle(
                color: Color(0xFFEAF8EF),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildRuntimeMonitor(),
          const SizedBox(height: 12),
          _buildConfigMonitor(),
        ],
      ),
    );
  }

  Widget _buildRelayStatusPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x44102D1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Status Relay',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _controlAccess.canManageControls
                ? 'Status relay ditampilkan realtime. Akses kontrol mobile saat ini aktif.'
                : 'Mode aplikasi saat ini hanya untuk monitoring. Status relay tetap ditampilkan realtime.',
            style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 12),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 760;
              final crossAxisCount = isWide ? 2 : 1;
              final compactPhone = constraints.maxWidth < 420;
              if (!isWide) {
                return Column(
                  children: _relayMetas
                      .map((relay) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _buildRelayCard(relay),
                          ))
                      .toList(),
                );
              }

              return GridView.count(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                childAspectRatio: compactPhone ? 1.65 : 1.95,
                children: _relayMetas.map(_buildRelayCard).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRuntimeMonitor() {
    final irrigationRuntimeText = _isIrrigationNftMode
        ? (_autoConfig.enabled ? 'Sensor AIR 24 jam aktif' : 'Sensor AIR menunggu AUTO aktif')
        : (_displayIrrigationRemaining > 0
            ? 'Irigasi aktif ${_fmtDuration(_displayIrrigationRemaining)}'
            : 'Irigasi idle');
    final items = <String>[
      'AUTO: ${_autoConfig.enabled ? 'Aktif' : 'Nonaktif'}',
      _displayNftRemaining > 0
          ? 'Sensor AIR aktif ${_fmtDuration(_displayNftRemaining)}'
          : 'Sensor AIR idle',
      _displayWarmupRemaining > 0
          ? 'Warmup sensor ${_fmtDuration(_displayWarmupRemaining)}'
          : (_autoConfig.sensorHoldActive ? 'Sensor hold aktif' : 'Sensor AIR idle'),
      irrigationRuntimeText,
      _displayDosingRemaining > 0 && _isNutritionDosingMode(_autoConfig.dosingMode)
          ? 'Dosing nutrisi ${_fmtDuration(_displayDosingRemaining)}'
          : (_displayNutritionCooldownRemaining > 0
              ? 'Cooldown nutrisi ${_fmtDuration(_displayNutritionCooldownRemaining)}'
              : 'Nutrisi idle'),
      _displayDosingRemaining > 0 && _isPhDosingMode(_autoConfig.dosingMode)
          ? 'Dosing ${_dosingModeText(_autoConfig.dosingMode)} ${_fmtDuration(_displayDosingRemaining)}'
          : (_displayPhCooldownRemaining > 0
              ? 'Cooldown pH ${_fmtDuration(_displayPhCooldownRemaining)}'
              : 'pH idle'),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x22184F2C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Runtime: ${_activeProcessLabel()}',
            style: const TextStyle(
              color: Color(0xFF9CCC65),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: items.map(_runtimeChip).toList(),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 380;
              return GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: compact ? 1.2 : 1.65,
                children: [
                  _runtimeTile('Sensor AIR', _fmtDuration(_displayNftRemaining)),
                  _runtimeTile('Warmup Sensor AIR', _fmtDuration(_displayWarmupRemaining)),
                  _runtimeTile(
                    'Irigasi',
                    _isIrrigationNftMode
                        ? (_autoConfig.enabled ? 'Sensor AIR 24J' : 'AUTO OFF')
                        : _fmtDuration(_displayIrrigationRemaining),
                  ),
                  _runtimeTile(
                    'Dosing Nutrisi',
                    _isNutritionDosingMode(_autoConfig.dosingMode)
                        ? _fmtDuration(_displayDosingRemaining)
                        : '00:00',
                  ),
                  _runtimeTile(
                    'Dosing pH',
                    _isPhDosingMode(_autoConfig.dosingMode)
                        ? _fmtDuration(_displayDosingRemaining)
                        : '00:00',
                  ),
                  _runtimeTile(
                    'Cooldown Nutrisi',
                    _fmtDuration(_displayNutritionCooldownRemaining),
                  ),
                  _runtimeTile(
                    'Cooldown pH',
                    _fmtDuration(_displayPhCooldownRemaining),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _runtimeChip(String text) {
    final active = !text.contains('idle') && !text.contains('Nonaktif');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF2E7D32) : const Color(0x22184F2C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? const Color(0xAA9CCC65) : const Color(0x33FFFFFF),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _runtimeTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x331C5A2A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigMonitor() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x331C5A2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Konfigurasi Aktif',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          _summaryRow('Sensor AIR', '${_autoConfig.nftIntervalMin} menit / ${_autoConfig.nftDurationMin} menit'),
          _summaryRow(
            'Irigasi',
            _isIrrigationNftMode
                ? '${_autoConfig.irrigationDurationSec} detik | Sensor AIR 24 jam'
                : '${_autoConfig.irrigationDurationSec} detik',
          ),
          _summaryRow('Target PPM', '${_autoConfig.targetPpm.toStringAsFixed(0)} | DB ${_autoConfig.ppmDeadband.toStringAsFixed(0)}'),
          _summaryRow('Target pH', '${_autoConfig.targetPh.toStringAsFixed(2)} | DB ${_autoConfig.phDeadband.toStringAsFixed(2)}'),
          _summaryRow('Pulse Nutrisi', '${_autoConfig.nutritionDosePulseSec} detik'),
          _summaryRow('Pulse pH', '${_autoConfig.phDosePulseSec} detik'),
          _summaryRow('Cooldown Nutrisi', '${_autoConfig.nutritionDosingCooldownSec} detik'),
          _summaryRow('Cooldown pH', '${_autoConfig.phDosingCooldownSec} detik'),
          _summaryRow('Warmup Sensor AIR', '${_autoConfig.nftSensorWarmupSec} detik'),
          _summaryRow('Target Air RO', _autoConfig.roTargetLabel),
          _summaryRow(
            'Jadwal Irigasi',
            _isIrrigationNftMode
                ? 'Mode Sensor AIR 24 jam aktif'
                : (_autoConfig.irrigationTimes.isEmpty
                    ? 'Belum ada'
                    : _autoConfig.irrigationTimes.join(', ')),
          ),
        ],
      ),
    );
  }

  Widget _buildControlAccessPanel() {
    final requiresPin = _controlAccess.requiresPin && !_controlAccess.bypassGranted;
    final canManage = _controlAccess.canManageControls;
    final remaining = _currentUnlockRemaining();
    final unlockInfo = _controlAccess.unlockExpiresAt == null
        ? null
        : 'Akses berlaku hingga ${_fmtDateTime(_controlAccess.unlockExpiresAt!)}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x44102D1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Akses Kontrol',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            canManage
                ? 'Akses kontrol indoor farming aktif di perangkat ini.'
                : (requiresPin
                    ? 'Konfigurasi dan kontrol tetap terlihat. PIN baru diminta saat Anda mengubah pengaturan atau menjalankan kontrol.'
                    : 'Akun ini memang hanya ditujukan untuk monitoring.'),
            style: const TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _runtimeChip('Role ${_controlAccess.role.toUpperCase()}'),
              _runtimeChip(canManage ? 'Kontrol aktif' : 'Monitoring saja'),
              if (_controlAccess.bypassGranted) _runtimeChip('Bypass tanpa PIN'),
              if (requiresPin) _runtimeChip('PIN ${_controlAccess.unlockDurationMinutes} menit'),
              if (canManage && remaining != null)
                _runtimeChip('Sisa ${_fmtCountdown(remaining)}'),
            ],
          ),
          if (_controlAccessError != null) ...[
            const SizedBox(height: 12),
            Text(
              _controlAccessError!,
              style: const TextStyle(
                color: Color(0xFFFFCDD2),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
          if (unlockInfo != null) ...[
            const SizedBox(height: 12),
            Text(
              unlockInfo,
              style: const TextStyle(
                color: Color(0xFF9BE7A2),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _controlAccessLoading
                      ? null
                      : (canManage
                          ? () => unawaited(_loadControlAccess(showLoading: true))
                          : (requiresPin
                              ? () => unawaited(
                                  _promptControlPin(target: 'config_control'),
                                )
                              : null)),
                  icon: Icon(canManage ? Icons.refresh_rounded : Icons.lock_open_rounded),
                  label: Text(
                    _controlAccessLoading
                        ? 'Memeriksa akses...'
                        : (canManage ? 'Refresh Akses' : 'Masukkan PIN'),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Color(0x33FFFFFF), height: 1),
          const SizedBox(height: 16),
          _buildControlPanelBody(),
        ],
      ),
    );
  }

  Widget _buildControlPanelBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Kontrol Indoor Farming',
          style: TextStyle(
            color: Color(0xFFF1F8E9),
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _controlAccess.canManageControls
              ? 'Akses sudah aktif. Saat ini target pengisian tandon RO bisa diubah langsung dari mobile.'
              : 'Panel tetap terlihat untuk monitoring. Saat Anda mengubah konfigurasi atau menjalankan kontrol, sistem akan meminta PIN.',
          style: const TextStyle(
            color: Color(0xFFC8E6C9),
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Target Pengisian Tandon RO',
          style: TextStyle(
            color: Color(0xFFF1F8E9),
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _roTargetChoiceChip('MID', 2),
            _roTargetChoiceChip('HIGH', 3),
          ],
        ),
        const SizedBox(height: 18),
        _buildAutoModeSection(),
        const SizedBox(height: 18),
        _buildConfigEditorSection(),
        const SizedBox(height: 18),
        _buildManualRelaySection(),
      ],
    );
  }

  Widget _buildAutoModeSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x331C5A2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mode Otomatis',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _autoConfig.enabled
                ? 'Sistem otomatis sedang aktif. Kontrol relay manual akan dikunci.'
                : 'Sistem otomatis sedang nonaktif. Kontrol relay manual bisa dipakai.',
            style: const TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _autoConfig.enabled
                      ? null
                      : () => unawaited(_setAutoModeEnabled()),
                  icon: const Icon(Icons.play_circle_outline_rounded),
                  label: const Text('Aktifkan AUTO'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _autoConfig.enabled
                      ? () => unawaited(_setAutoModeDisabled())
                      : null,
                  icon: const Icon(Icons.pause_circle_outline_rounded),
                  label: const Text('Matikan AUTO'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0x55FFFFFF)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: () => unawaited(_resetRuntime()),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Reset Runtime'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF9BE7A2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigEditorSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x331C5A2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Konfigurasi Auto',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          _configActionTile(
            title: 'NFT',
            value: '${_autoConfig.nftIntervalMin} menit / ${_autoConfig.nftDurationMin} menit',
            subtitle: 'Atur interval dan durasi siklus NFT',
            onTap: _editNftConfig,
          ),
          _configActionTile(
            title: 'Irigasi',
            value: _isIrrigationNftMode
                ? '${_autoConfig.irrigationDurationSec} detik | NFT 24 jam'
                : '${_autoConfig.irrigationDurationSec} detik',
            subtitle: _isIrrigationNftMode
                ? 'Pompa irigasi menyala terus saat AUTO aktif'
                : (_autoConfig.irrigationTimes.isEmpty
                    ? 'Belum ada jadwal'
                    : _autoConfig.irrigationTimes.join(', ')),
            onTap: _editIrrigationConfig,
          ),
          _configActionTile(
            title: 'Target PPM',
            value:
                '${_autoConfig.targetPpm.toStringAsFixed(0)} | DB ${_autoConfig.ppmDeadband.toStringAsFixed(0)}',
            subtitle: 'Target dan deadband nutrisi',
            onTap: _editPpmConfig,
          ),
          _configActionTile(
            title: 'Target pH',
            value:
                '${_autoConfig.targetPh.toStringAsFixed(2)} | DB ${_autoConfig.phDeadband.toStringAsFixed(2)}',
            subtitle: 'Target dan deadband pH',
            onTap: _editPhConfig,
          ),
          _configActionTile(
            title: 'Dosing Nutrisi',
            value:
                'Pulse ${_autoConfig.nutritionDosePulseSec}s | Cooldown ${_autoConfig.nutritionDosingCooldownSec}s',
            subtitle: 'Pengaturan dosing A+B',
            onTap: _editNutritionDosingConfig,
          ),
          _configActionTile(
            title: 'Dosing pH',
            value:
                'Pulse ${_autoConfig.phDosePulseSec}s | Cooldown ${_autoConfig.phDosingCooldownSec}s',
            subtitle: 'Pengaturan dosing pH UP / DOWN',
            onTap: _editPhDosingConfig,
          ),
        ],
      ),
    );
  }

  Widget _buildManualRelaySection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x331C5A2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Kontrol Relay Manual',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _autoConfig.enabled
                ? 'Matikan AUTO lebih dulu untuk mengendalikan relay dari mobile.'
                : (_manualControlMode == 'timer'
                    ? 'AUTO sedang OFF. Saat tombol ON ditekan, relay akan mati otomatis sesuai timer.'
                    : 'AUTO sedang OFF. Anda bisa menyalakan atau mematikan relay manual.'),
            style: const TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ChoiceChip(
                label: const Text('Manual Biasa'),
                selected: _manualControlMode == 'direct',
                onSelected: (_) => _setManualControlMode('direct'),
                selectedColor: const Color(0xFF2E7D32),
                labelStyle: TextStyle(
                  color: _manualControlMode == 'direct'
                      ? Colors.white
                      : const Color(0xFFF1F8E9),
                  fontWeight: FontWeight.w700,
                ),
                side: const BorderSide(color: Color(0x55FFFFFF)),
              ),
              ChoiceChip(
                label: const Text('Manual + Timer'),
                selected: _manualControlMode == 'timer',
                onSelected: (_) => _setManualControlMode('timer'),
                selectedColor: const Color(0xFF2E7D32),
                labelStyle: TextStyle(
                  color: _manualControlMode == 'timer'
                      ? Colors.white
                      : const Color(0xFFF1F8E9),
                  fontWeight: FontWeight.w700,
                ),
                side: const BorderSide(color: Color(0x55FFFFFF)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._relayMetas.map(_buildManualRelayControlCard),
        ],
      ),
    );
  }

  Widget _configActionTile({
    required String title,
    required String value,
    required String subtitle,
    required Future<void> Function() onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => unawaited(onTap()),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x22184F2C),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFF1F8E9),
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFFC8E6C9),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      value,
                      style: const TextStyle(
                        color: Color(0xFF9BE7A2),
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.edit_rounded, color: Color(0xFFEAF8EF)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManualRelayControlCard(_RelayMeta relay) {
    final isOn = _relayStates[relay.key] == true;
    final disabled = _autoConfig.enabled;
    final timerConfig = _manualTimerConfig[relay.key] ?? const _ManualTimerConfig();
    final timerRemaining = _manualRelayRemaining(relay.key);
    final timerActive =
        timerRemaining != null && timerRemaining.inMilliseconds > 0;
    final timerMode = _manualControlMode == 'timer';
    final timerNote = timerActive
        ? 'Akan mati otomatis dalam ${_fmtCountdown(timerRemaining!)}'
        : 'Preset timer ${timerConfig.label}. Timer berjalan saat tombol ON dipakai.';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x22184F2C),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        relay.title,
                        style: const TextStyle(
                          color: Color(0xFFF1F8E9),
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        relay.subtitle,
                        style: const TextStyle(
                          color: Color(0xFFC8E6C9),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: timerActive
                        ? const Color(0xFF00897B)
                        : (isOn
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFF5D4037)),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    timerActive
                        ? 'TIMER ${_fmtCountdown(timerRemaining!)}'
                        : (isOn ? 'ON' : 'OFF'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            if (timerMode) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x1AFFFFFF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x22FFFFFF)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Preset timer: ${timerConfig.label}',
                            style: const TextStyle(
                              color: Color(0xFFF1F8E9),
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: disabled
                              ? null
                              : () => unawaited(_editManualTimerPreset(relay)),
                          icon: const Icon(Icons.timer_outlined, size: 18),
                          label: const Text('Atur Timer'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF9BE7A2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      timerNote,
                      style: const TextStyle(
                        color: Color(0xFFC8E6C9),
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => unawaited(_setRelayManually(relay.key, false)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0x55FFFFFF)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('OFF'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: disabled
                        ? null
                        : () => unawaited(
                            _setRelayManually(
                              relay.key,
                              true,
                              manualDurationMs: timerMode
                                  ? timerConfig.durationMs
                                  : null,
                            ),
                          ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(timerMode ? 'ON + Timer' : 'ON'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelayCard(_RelayMeta relay) {
    final isOn = _relayStates[relay.key] == true;
    final lockedByAuto = _autoConfig.enabled && _isAutoManagedRelay(relay.key);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x22184F2C),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isOn ? const Color(0xAA66BB6A) : const Color(0x33FFFFFF),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      relay.title,
                      style: const TextStyle(
                        color: Color(0xFFF1F8E9),
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      relay.subtitle,
                      style: const TextStyle(
                        color: Color(0xFFC8E6C9),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      lockedByAuto ? 'Mode otomatis' : 'Kontrol manual',
                      style: TextStyle(
                        color: lockedByAuto
                            ? const Color(0xFFFFF59D)
                            : (isOn ? const Color(0xFF9BE7A2) : const Color(0xFFB7D8BD)),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isOn ? const Color(0xFF2E7D32) : const Color(0xFF5D4037),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  isOn ? 'ON' : 'OFF',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0x331C5A2A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
            child: Text(
              lockedByAuto
                  ? 'Relay ini mengikuti sistem AUTO dari device.'
                  : (isOn ? 'Relay aktif dari device.' : 'Relay sedang OFF di device.'),
              style: const TextStyle(
                color: Color(0xFFEAF8EF),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isAutoManagedRelay(String key) {
    return key == 'do1' || key == 'do2' || key == 'do3' || key == 'do4' || key == 'do5' || key == 'do6' || key == 'do7';
  }

  Widget _buildWaterTankPanel() {
    final fillRatio = switch (_waterLevel.currentLevel) {
      >= 3 => 0.94,
      2 => 0.68,
      1 => 0.34,
      _ => 0.08,
    };
    final waterColor = switch (_waterLevel.currentLevel) {
      >= 3 => const Color(0xFF29B6F6),
      2 => const Color(0xFF26C6DA),
      1 => const Color(0xFF4DD0E1),
      _ => const Color(0x3329B6F6),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x55113322),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tandon Air RO',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Indikator visual level air realtime berdasarkan sensor DI1, DI2, dan DI3.',
            style: TextStyle(color: Color(0xFFC8E6C9), fontSize: 12),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final vertical = constraints.maxWidth < 620;
              final tank = _buildTankGraphic(fillRatio, waterColor);
              final detail = _buildWaterLevelDetail();
              if (vertical) {
                return Column(
                  children: [
                    tank,
                    const SizedBox(height: 16),
                    detail,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 210, child: tank),
                  const SizedBox(width: 18),
                  Expanded(child: detail),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTankGraphic(double fillRatio, Color waterColor) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x22184F2C),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        children: [
          SizedBox(
            width: 120,
            height: 190,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xAAEAF8EF), width: 3),
                    gradient: const LinearGradient(
                      colors: [Color(0x111FFFFFF), Color(0x22FFFFFF)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: fillRatio),
                          duration: const Duration(milliseconds: 600),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, child) {
                            return FractionallySizedBox(
                              heightFactor: value.clamp(0.0, 1.0),
                              widthFactor: 1,
                              alignment: Alignment.bottomCenter,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      waterColor.withOpacity(0.95),
                                      waterColor.withOpacity(0.70),
                                    ],
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                  ),
                                ),
                                child: child,
                              ),
                            );
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: Colors.white.withOpacity(0.55),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 18,
                  right: 8,
                  child: _tankMarker('HIGH'),
                ),
                Positioned(
                  top: 84,
                  right: 8,
                  child: _tankMarker('MID'),
                ),
                Positioned(
                  bottom: 28,
                  right: 8,
                  child: _tankMarker('LOW'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _waterLevel.currentLabel,
            style: const TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _waterLevel.roFillActive ? 'Pompa RO sedang mengisi' : 'Pompa RO siaga',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _waterLevel.roFillActive
                  ? const Color(0xFF9BE7A2)
                  : const Color(0xFFC8E6C9),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tankMarker(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xAA0C3418),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFC8E6C9),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildWaterLevelDetail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _statusChip('DI1 ${_waterLevel.lowActive ? 'ACTIVE' : '0'}', _waterLevel.lowActive),
            _statusChip('DI2 ${_waterLevel.midActive ? 'ACTIVE' : '0'}', _waterLevel.midActive),
            _statusChip('DI3 ${_waterLevel.highActive ? 'ACTIVE' : '0'}', _waterLevel.highActive),
            _runtimeChip('Target ${_autoConfig.roTargetLabel}'),
          ],
        ),
        const SizedBox(height: 14),
        _summaryRow('Level Air Saat Ini', _waterLevel.currentLabel),
        _summaryRow('Pompa RO', _waterLevel.roFillActive ? 'ON' : 'OFF'),
        _summaryRow('Sensor DI1', _waterLevel.lowActive ? 'HIGH / aktif' : '0'),
        _summaryRow('Sensor DI2', _waterLevel.midActive ? 'HIGH / aktif' : '0'),
        _summaryRow('Sensor DI3', _waterLevel.highActive ? 'HIGH / aktif' : '0'),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x22184F2C),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: const Text(
            'Logika aktif: 000 = EMPTY, 100 = LOW, 110 = MID, 111 = HIGH. Pompa RO memakai relay DO7.',
            style: TextStyle(
              color: Color(0xFFEAF8EF),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }

  Widget _roTargetChoiceChip(String label, int level) {
    final active = _autoConfig.roTargetLevel == level;
    return ChoiceChip(
      label: Text('Isi hingga $label'),
      selected: active,
      selectedColor: const Color(0xFF2E7D32),
      backgroundColor: const Color(0x331A4A28),
      side: const BorderSide(color: Color(0x55FFFFFF)),
      labelStyle: TextStyle(
        color: active ? Colors.white : const Color(0xFFEAF8EF),
        fontWeight: FontWeight.w700,
      ),
      onSelected: (_) => _setRoTargetLevel(level),
    );
  }

  Future<void> _setRoTargetLevel(int level) async {
    await _runWithControlAccess(
      target: 'control',
      action: () async {
        await ActivityLoggerService.log(
          action: 'auto_config.ro_target',
          module: 'indoor_farming',
          description: 'Mengubah target pengisian air RO ke ${level >= 3 ? 'HIGH' : 'MID'}',
          deviceId: IndoorFarmingMqttService.defaultDeviceId,
        );
        await _service.setAutoConfig(roTargetLevel: level);
        unawaited(_loadBackendAutoConfig());
        unawaited(_service.requestStatus());
      },
    );
  }

  Future<void> _setAutoModeEnabled() async {
    await _runWithControlAccess(
      target: 'control',
      action: () async {
        await ActivityLoggerService.log(
          action: 'auto_mode.enable',
          module: 'indoor_farming',
          description: 'Mengaktifkan mode auto indoor farming dari mobile',
          deviceId: IndoorFarmingMqttService.defaultDeviceId,
        );
        await _service.setAutoMode(true);
        unawaited(_service.requestStatus());
      },
    );
  }

  Future<void> _setAutoModeDisabled() async {
    await _runWithControlAccess(
      target: 'control',
      action: () async {
        await ActivityLoggerService.log(
          action: 'auto_mode.disable',
          module: 'indoor_farming',
          description: 'Menonaktifkan mode auto indoor farming dari mobile',
          deviceId: IndoorFarmingMqttService.defaultDeviceId,
        );
        await _service.setAutoMode(false);
        unawaited(_service.requestStatus());
      },
    );
  }

  Future<void> _resetRuntime() async {
    await _runWithControlAccess(
      target: 'control',
      action: () async {
        await ActivityLoggerService.log(
          action: 'auto_config.reset_runtime',
          module: 'indoor_farming',
          description: 'Reset runtime indoor farming dari mobile',
          deviceId: IndoorFarmingMqttService.defaultDeviceId,
        );
        await _service.setAutoConfig(resetRuntime: true);
        unawaited(_service.requestStatus());
      },
    );
  }

  Future<void> _setRelayManually(
    String relayKey,
    bool on, {
    int? manualDurationMs,
  }) async {
    await _setRelayManuallyInternal(
      relayKey,
      on,
      manualDurationMs: manualDurationMs,
    );
  }

  Future<void> _setRelayManuallyInternal(
    String relayKey,
    bool on, {
    int? manualDurationMs,
    bool requireAccess = true,
  }) async {
    final runner = () async {
      final usingTimer = on && (manualDurationMs ?? 0) > 0;
      await ActivityLoggerService.log(
        action: usingTimer ? 'relay.manual_timer' : 'relay.manual',
        module: 'indoor_farming',
        description: usingTimer
            ? 'Mengubah relay $relayKey menjadi ON dengan timer ${_fmtManualDuration(manualDurationMs!)} dari mobile'
            : 'Mengubah relay $relayKey menjadi ${on ? 'ON' : 'OFF'} dari mobile',
        deviceId: IndoorFarmingMqttService.defaultDeviceId,
      );
      await _service.setRelayState(relayKey, on);
      unawaited(_service.requestStatus());
      if (!mounted) return;
      setState(() {
        _relayStates[relayKey] = on;
        if (usingTimer && !_autoConfig.enabled) {
          _manualRelayDeadlines[relayKey] = DateTime.now().add(
            Duration(milliseconds: manualDurationMs!),
          );
        } else {
          _manualRelayDeadlines[relayKey] = null;
        }
      });
    };

    if (requireAccess) {
      await _runWithControlAccess(target: 'control', action: runner);
      return;
    }
    await runner();
  }

  Future<void> _expireManualRelay(String relayKey) async {
    if (_autoConfig.enabled || _relayStates[relayKey] != true) return;
    await ActivityLoggerService.log(
      action: 'relay.manual_timer_expired',
      module: 'indoor_farming',
      description: 'Timer manual relay $relayKey habis dan relay dimatikan otomatis dari mobile',
      deviceId: IndoorFarmingMqttService.defaultDeviceId,
    );
    await _service.setRelayState(relayKey, false);
    unawaited(_service.requestStatus());
    if (!mounted) return;
    setState(() {
      _relayStates[relayKey] = false;
      _manualRelayDeadlines[relayKey] = null;
    });
  }

  Future<void> _editManualTimerPreset(_RelayMeta relay) async {
    final current =
        _manualTimerConfig[relay.key] ?? const _ManualTimerConfig();
    final controller = TextEditingController(text: current.amount.toString());
    var unit = current.unit;

    final result = await showDialog<_ManualTimerConfig>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF183625),
              title: Text('Timer ${relay.title}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Durasi',
                      labelStyle: TextStyle(color: Color(0xFFC8E6C9)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: unit,
                    dropdownColor: const Color(0xFF214733),
                    decoration: const InputDecoration(
                      labelText: 'Satuan',
                      labelStyle: TextStyle(color: Color(0xFFC8E6C9)),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'seconds',
                        child: Text('Detik'),
                      ),
                      DropdownMenuItem(
                        value: 'minutes',
                        child: Text('Menit'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        unit = value;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Preset ini dipakai saat tombol ON + Timer ditekan.',
                    style: TextStyle(
                      color: Color(0xFFC8E6C9),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Batal'),
                ),
                FilledButton(
                  onPressed: () {
                    final amount = int.tryParse(controller.text.trim()) ?? 30;
                    Navigator.of(dialogContext).pop(
                      _ManualTimerConfig(
                        amount: math.max(1, amount),
                        unit: unit == 'minutes' ? 'minutes' : 'seconds',
                      ),
                    );
                  },
                  child: const Text('Simpan'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
    if (!mounted || result == null) return;
    setState(() {
      _manualTimerConfig[relay.key] = result;
    });
  }

  Future<void> _editNftConfig() async {
    final unlocked = await _ensureAccessUnlocked('config');
    if (!mounted || !unlocked) return;

    final result = await _showConfigInputDialog(
      title: 'Konfigurasi NFT',
      fields: [
        _ConfigInputField(
          key: 'interval',
          label: 'Interval NFT (menit)',
          initialValue: _autoConfig.nftIntervalMin.toString(),
          keyboardType: TextInputType.number,
        ),
        _ConfigInputField(
          key: 'duration',
          label: 'Durasi NFT (menit)',
          initialValue: _autoConfig.nftDurationMin.toString(),
          keyboardType: TextInputType.number,
        ),
        _ConfigInputField(
          key: 'warmup',
          label: 'Warmup sensor NFT (30/60 detik)',
          initialValue: _autoConfig.nftSensorWarmupSec.toString(),
          keyboardType: TextInputType.number,
        ),
      ],
    );
    if (result == null) return;
    await _service.setAutoConfig(
      nftIntervalMinutes: int.tryParse(result['interval'] ?? ''),
      nftDurationMinutes: int.tryParse(result['duration'] ?? ''),
      nftSensorWarmupSeconds: int.tryParse(result['warmup'] ?? ''),
    );
    unawaited(_loadBackendAutoConfig());
    unawaited(_service.requestStatus());
  }

  Future<void> _editIrrigationConfig() async {
    final unlocked = await _ensureAccessUnlocked('config');
    if (!mounted || !unlocked) return;

    final result = await _showIrrigationConfigDialog();
    if (result == null) return;
    final times = _normalizeScheduleInput(result['times'] ?? '');
    await _service.setAutoConfig(
      irrigationDurationSeconds: int.tryParse(result['duration'] ?? ''),
      irrigationMode: result['mode'] == 'nft' ? 'nft' : 'schedule',
      irrigationTimes: result['mode'] == 'nft' ? <String>[] : times,
    );
    unawaited(_loadBackendAutoConfig());
    unawaited(_service.requestStatus());
  }

  Future<Map<String, String>?> _showIrrigationConfigDialog() async {
    final durationController = TextEditingController(
      text: _autoConfig.irrigationDurationSec.toString(),
    );
    final timesController = TextEditingController(
      text: _autoConfig.irrigationTimes.join(', '),
    );
    String selectedMode = _isIrrigationNftMode ? 'nft' : 'schedule';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final nftMode = selectedMode == 'nft';
            return AlertDialog(
              backgroundColor: const Color(0xFF10311E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text(
                'Konfigurasi Irigasi',
                style: TextStyle(
                  color: Color(0xFFF1F8E9),
                  fontWeight: FontWeight.w800,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Mode Irigasi',
                      style: TextStyle(
                        color: Color(0xFFC8E6C9),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Jadwal Jam'),
                          selected: selectedMode == 'schedule',
                          onSelected: (_) => setDialogState(() {
                            selectedMode = 'schedule';
                          }),
                        ),
                        ChoiceChip(
                          label: const Text('NFT 24 Jam'),
                          selected: selectedMode == 'nft',
                          onSelected: (_) => setDialogState(() {
                            selectedMode = 'nft';
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: durationController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Color(0xFFF1F8E9)),
                      decoration: InputDecoration(
                        labelText: 'Durasi irigasi (detik)',
                        labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
                        filled: true,
                        fillColor: const Color(0x331C5A2A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: timesController,
                      enabled: !nftMode,
                      keyboardType: TextInputType.text,
                      style: TextStyle(
                        color: nftMode
                            ? const Color(0x88F1F8E9)
                            : const Color(0xFFF1F8E9),
                      ),
                      decoration: InputDecoration(
                        labelText: 'Jadwal irigasi (pisahkan dengan koma)',
                        helperText: nftMode
                            ? 'Mode NFT aktif. Jadwal jam tidak dipakai.'
                            : 'Contoh: 06:00, 12:00, 18:00',
                        helperStyle: const TextStyle(color: Color(0xFFC8E6C9)),
                        labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
                        filled: true,
                        fillColor: const Color(0x331C5A2A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    if (nftMode) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0x22184F2C),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: const Text(
                          'Pompa irigasi akan menyala terus selama mode AUTO aktif.',
                          style: TextStyle(
                            color: Color(0xFFF1F8E9),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Batal'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(<String, String>{
                      'mode': selectedMode,
                      'duration': durationController.text.trim(),
                      'times': timesController.text.trim(),
                    });
                  },
                  child: const Text('Simpan'),
                ),
              ],
            );
          },
        );
      },
    );

    durationController.dispose();
    timesController.dispose();
    return result;
  }

  Future<void> _editPpmConfig() async {
    final unlocked = await _ensureAccessUnlocked('config');
    if (!mounted || !unlocked) return;

    final result = await _showConfigInputDialog(
      title: 'Target PPM',
      fields: [
        _ConfigInputField(
          key: 'target',
          label: 'Target PPM',
          initialValue: _autoConfig.targetPpm.toStringAsFixed(0),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        _ConfigInputField(
          key: 'deadband',
          label: 'Deadband PPM',
          initialValue: _autoConfig.ppmDeadband.toStringAsFixed(0),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ],
    );
    if (result == null) return;
    await _service.setAutoConfig(
      targetPpm: double.tryParse(result['target'] ?? ''),
      ppmDeadband: double.tryParse(result['deadband'] ?? ''),
    );
    unawaited(_loadBackendAutoConfig());
    unawaited(_service.requestStatus());
  }

  Future<void> _editPhConfig() async {
    final unlocked = await _ensureAccessUnlocked('config');
    if (!mounted || !unlocked) return;

    final result = await _showConfigInputDialog(
      title: 'Target pH',
      fields: [
        _ConfigInputField(
          key: 'target',
          label: 'Target pH',
          initialValue: _autoConfig.targetPh.toStringAsFixed(2),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        _ConfigInputField(
          key: 'deadband',
          label: 'Deadband pH',
          initialValue: _autoConfig.phDeadband.toStringAsFixed(2),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ],
    );
    if (result == null) return;
    await _service.setAutoConfig(
      targetPh: double.tryParse(result['target'] ?? ''),
      phDeadband: double.tryParse(result['deadband'] ?? ''),
    );
    unawaited(_loadBackendAutoConfig());
    unawaited(_service.requestStatus());
  }

  Future<void> _editNutritionDosingConfig() async {
    final unlocked = await _ensureAccessUnlocked('config');
    if (!mounted || !unlocked) return;

    final result = await _showConfigInputDialog(
      title: 'Dosing Nutrisi',
      fields: [
        _ConfigInputField(
          key: 'pulse',
          label: 'Pulse nutrisi (detik)',
          initialValue: _autoConfig.nutritionDosePulseSec.toString(),
          keyboardType: TextInputType.number,
        ),
        _ConfigInputField(
          key: 'cooldown',
          label: 'Cooldown nutrisi (detik)',
          initialValue: _autoConfig.nutritionDosingCooldownSec.toString(),
          keyboardType: TextInputType.number,
        ),
      ],
    );
    if (result == null) return;
    await _service.setAutoConfig(
      nutritionDosePulseSeconds: int.tryParse(result['pulse'] ?? ''),
      nutritionDosingCooldownSeconds: int.tryParse(result['cooldown'] ?? ''),
    );
    unawaited(_loadBackendAutoConfig());
    unawaited(_service.requestStatus());
  }

  Future<void> _editPhDosingConfig() async {
    final unlocked = await _ensureAccessUnlocked('config');
    if (!mounted || !unlocked) return;

    final result = await _showConfigInputDialog(
      title: 'Dosing pH',
      fields: [
        _ConfigInputField(
          key: 'pulse',
          label: 'Pulse pH (detik)',
          initialValue: _autoConfig.phDosePulseSec.toString(),
          keyboardType: TextInputType.number,
        ),
        _ConfigInputField(
          key: 'cooldown',
          label: 'Cooldown pH (detik)',
          initialValue: _autoConfig.phDosingCooldownSec.toString(),
          keyboardType: TextInputType.number,
        ),
      ],
    );
    if (result == null) return;
    await _service.setAutoConfig(
      phDosePulseSeconds: int.tryParse(result['pulse'] ?? ''),
      phDosingCooldownSeconds: int.tryParse(result['cooldown'] ?? ''),
    );
    unawaited(_loadBackendAutoConfig());
    unawaited(_service.requestStatus());
  }

  Future<Map<String, String>?> _showConfigInputDialog({
    required String title,
    required List<_ConfigInputField> fields,
  }) async {
    final controllers = <String, TextEditingController>{
      for (final field in fields)
        field.key: TextEditingController(text: field.initialValue),
    };

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF10311E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            title,
            style: const TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: fields
                  .map(
                    (field) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: controllers[field.key],
                        keyboardType: field.keyboardType,
                        style: const TextStyle(color: Color(0xFFF1F8E9)),
                        decoration: InputDecoration(
                          labelText: field.label,
                          labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
                          filled: true,
                          fillColor: const Color(0x331C5A2A),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(
                  <String, String>{
                    for (final field in fields)
                      field.key: controllers[field.key]!.text.trim(),
                  },
                );
              },
              child: const Text('Simpan'),
            ),
          ],
        );
      },
    );

    for (final controller in controllers.values) {
      controller.dispose();
    }
    return result;
  }

  List<String> _normalizeScheduleInput(String raw) {
    if (raw.trim().isEmpty) return <String>[];
    final values = raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(item))
        .toSet()
        .toList()
      ..sort();
    return values;
  }

  Widget _statusChip(String text, bool active) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF2E7D32) : const Color(0x22184F2C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? const Color(0xAA9CCC65) : const Color(0x33FFFFFF),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }


  Widget _summaryRow(String label, String value) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 320;
        if (narrow) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFC8E6C9),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    softWrap: true,
                    style: const TextStyle(
                      color: Color(0xFFF1F8E9),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFC8E6C9),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  softWrap: true,
                  style: const TextStyle(
                    color: Color(0xFFF1F8E9),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  double _minY(List<FlSpot> spots) {
    final min = spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final max = spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    if (min == max) return min - 1;
    return min - ((max - min) * 0.12);
  }

  double _maxY(List<FlSpot> spots) {
    final min = spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final max = spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    if (min == max) return max + 1;
    return max + ((max - min) * 0.12);
  }

  double _yInterval(List<FlSpot> spots) {
    final min = spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final max = spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    final diff = (max - min).abs();
    if (diff <= 1) return 0.5;
    if (diff <= 5) return 1;
    if (diff <= 20) return 5;
    if (diff <= 100) return 10;
    return diff / 4;
  }

  double _xInterval(int length) {
    if (length <= 8) return 1;
    if (length <= 24) return 4;
    if (length <= 60) return 10;
    return 20;
  }

  double _xIntervalForTime(List<FlSpot> spots) {
    final option = MongoHistoryService.rangeOptions[_selectedRange] ??
        MongoHistoryService.rangeOptions['15m']!;
    return switch (option.minutes) {
      <= 5 => const Duration(minutes: 2).inMilliseconds.toDouble(),
      <= 10 => const Duration(minutes: 4).inMilliseconds.toDouble(),
      <= 15 => const Duration(minutes: 6).inMilliseconds.toDouble(),
      <= 20 => const Duration(minutes: 8).inMilliseconds.toDouble(),
      _ => const Duration(minutes: 10).inMilliseconds.toDouble(),
    };
  }

  (double, double) _chartAxisRange(List<FlSpot> spots) {
    final option = MongoHistoryService.rangeOptions[_selectedRange] ??
        MongoHistoryService.rangeOptions['15m']!;
    final rangeMs = Duration(minutes: option.minutes).inMilliseconds.toDouble();
    final nowX = DateTime.now().millisecondsSinceEpoch.toDouble();

    if (spots.isEmpty) {
      return (nowX - rangeMs, nowX);
    }

    final lastX = math.max(spots.last.x, nowX);
    return (lastX - rangeMs, lastX);
  }

  String _xToMongoLabel(double value) {
    final at = DateTime.fromMillisecondsSinceEpoch(value.round()).toLocal();
    final hh = at.hour.toString().padLeft(2, '0');
    final min = at.minute.toString().padLeft(2, '0');
    return '$hh:$min';
  }

  bool _shouldShowMongoXAxisLabel(
    double value,
    TitleMeta meta,
    List<FlSpot> spots,
  ) {
    if (spots.isEmpty) return false;

    final axisRange = meta.max - meta.min;
    if (axisRange <= 0) return false;

    final ratio = (value - meta.min) / axisRange;
    if (ratio < 0.06 || ratio > 0.94) {
      return false;
    }

    final option = MongoHistoryService.rangeOptions[_selectedRange] ??
        MongoHistoryService.rangeOptions['15m']!;
    final labelMinuteStep = switch (option.minutes) {
      <= 5 => 2,
      <= 10 => 4,
      <= 15 => 6,
      <= 20 => 8,
      _ => 10,
    };

    final at = DateTime.fromMillisecondsSinceEpoch(value.round()).toLocal();
    return at.minute % labelMinuteStep == 0;
  }

  int _metricDecimals(String label) {
    switch (label) {
      case 'EC':
        return 2;
      case 'pH':
        return 3;
      default:
        return 2;
    }
  }

  IconData _metricIcon(String label) {
    switch (label) {
      case 'EC':
        return Icons.bolt_rounded;
      case 'PPM':
        return Icons.tune_rounded;
      case 'Oksigen':
        return Icons.bubble_chart_rounded;
      case 'Suhu':
        return Icons.thermostat_rounded;
      case 'TDS':
        return Icons.water_drop_rounded;
      case 'pH':
        return Icons.science_rounded;
      default:
        return Icons.sensors_rounded;
    }
  }

  String _fmt(double? value, int digits) {
    if (value == null || value.isNaN || value.isInfinite) return '--';
    return value.toStringAsFixed(digits);
  }

  String _fmtDuration(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final minutes = safe ~/ 60;
    final remainingSeconds = safe % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  bool _isNutritionDosingMode(int mode) => mode == 1;

  bool _isPhDosingMode(int mode) => mode == 2 || mode == 3;

  String _dosingModeText(int mode) {
    switch (mode) {
      case 1:
        return 'Nutrisi A+B';
      case 2:
        return 'pH UP';
      case 3:
        return 'pH DOWN';
      default:
        return 'Idle';
    }
  }

  String _fmtManualDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final totalSeconds = math.max(1, duration.inSeconds);
    if (totalSeconds % 60 == 0 && totalSeconds >= 60) {
      return '${totalSeconds ~/ 60} menit';
    }
    return '$totalSeconds detik';
  }

  String? _activeManualTimerLabel() {
    for (final relay in _relayMetas) {
      final remaining = _manualRelayRemaining(relay.key);
      if (remaining == null || remaining.inMilliseconds <= 0) continue;
      return '${relay.title} ${_fmtCountdown(remaining)}';
    }
    return null;
  }

  String _activeProcessLabel() {
    final manualTimerLabel = _activeManualTimerLabel();
    if (!_autoConfig.enabled && manualTimerLabel != null) {
      return 'Timer $manualTimerLabel';
    }
    if (_displayDosingRemaining > 0) {
      if (_isNutritionDosingMode(_autoConfig.dosingMode)) return 'Dosing Nutrisi';
      if (_isPhDosingMode(_autoConfig.dosingMode)) {
        return 'Dosing ${_dosingModeText(_autoConfig.dosingMode)}';
      }
      return 'Dosing';
    }
    if (_autoConfig.nftSensorWarmupActive || _displayWarmupRemaining > 0) {
      return 'Warmup Sensor NFT';
    }
    if (_displayNutritionCooldownRemaining > 0) return 'Cooldown Nutrisi';
    if (_displayPhCooldownRemaining > 0) return 'Cooldown pH';
    if (_isIrrigationNftMode && _autoConfig.enabled) return 'NFT Irigasi 24 Jam';
    if (_displayIrrigationRemaining > 0) return 'Pompa Irigasi';
    if (_displayNftRemaining > 0) return 'Siklus NFT';
    return _autoConfig.enabled ? 'Menunggu trigger berikutnya' : 'Standby';
  }

  bool get _isIrrigationNftMode => _autoConfig.irrigationMode == 'nft';

  String _fmtDateTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }
}

class _IndoorMetricMeta {
  final String label;
  final String unit;
  final Color color;
  final int decimals;

  const _IndoorMetricMeta({
    required this.label,
    required this.unit,
    required this.color,
    required this.decimals,
  });
}

class _RelayMeta {
  final String key;
  final String title;
  final String subtitle;

  const _RelayMeta({
    required this.key,
    required this.title,
    required this.subtitle,
  });
}

class _ManualTimerConfig {
  final int amount;
  final String unit;

  const _ManualTimerConfig({
    this.amount = 30,
    this.unit = 'seconds',
  });

  int get durationMs {
    final safeAmount = math.max(1, amount);
    if (unit == 'minutes') return safeAmount * 60 * 1000;
    return safeAmount * 1000;
  }

  String get label => unit == 'minutes' ? '$amount menit' : '$amount detik';
}

class _ConfigInputField {
  final String key;
  final String label;
  final String initialValue;
  final TextInputType keyboardType;

  const _ConfigInputField({
    required this.key,
    required this.label,
    required this.initialValue,
    required this.keyboardType,
  });
}

class _MongoChartPoint {
  final DateTime at;
  final double value;

  const _MongoChartPoint({
    required this.at,
    required this.value,
  });
}
