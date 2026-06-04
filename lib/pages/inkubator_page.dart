import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../controllers/inkubator_controller.dart';
import '../services/mqtt_device_service.dart';
import '../services/mqtt_service.dart';
import '../services/mongo_history_service.dart';
import 'package:mqtt_client/mqtt_client.dart';

import '../widgets/header_widget.dart';
import '../widgets/relay_switch.dart';
import '../widgets/temperature_card.dart';
import '../widgets/plant_tile.dart';
import '../widgets/sticky_header_delegate.dart';
import '../widgets/esp_status_card.dart';
import '../widgets/watering_time_tile.dart';
import '../widgets/industrial_card.dart';
import 'package:flutter_switch/flutter_switch.dart';
import 'add_plant_page.dart';
import '../services/activity_logger_service.dart';
import '../services/app_session_service.dart';

class InkubatorPage extends StatefulWidget {
  final String deviceId;

  const InkubatorPage({
    super.key,
    required this.deviceId,
  });

  @override
  State<InkubatorPage> createState() => _InkubatorPageState();
}

class _InkubatorPageState extends State<InkubatorPage>
    with WidgetsBindingObserver {
  late final MqttDeviceService deviceService;
  late final InkubatorController controller;
  late final VoidCallback markDirty;
  final ValueNotifier<int> _chartTick = ValueNotifier(0);
  final List<_ChartSample> _temperatureHistory = <_ChartSample>[];
  final List<_ChartSample> _humidityHistory = <_ChartSample>[];
  final List<_ChartSample> _soilMoistureHistory = <_ChartSample>[];
  StreamSubscription<double?>? _tempChartSub;
  StreamSubscription<double?>? _humChartSub;
  StreamSubscription<double?>? _soilChartSub;
  Timer? _historyReloadTimer;
  String _chartRangeKey = '15m';
  String _selectedChartMetric = 'temperature';
  bool _historyReloading = false;
  String? _chartError;

  _RealtimeTempComparison _buildRealtimeTempComparison(double temp) {
    final mode = controller.currentMode.value;
    final hasPlant = controller.hasActivePlant.value;
    final minT = controller.minTemp.value;
    final maxT = controller.maxTemp.value;

    if (mode != "auto") {
      return const _RealtimeTempComparison(
        status: "Manual",
        color: Colors.grey,
        detail: "Perbandingan otomatis nonaktif",
      );
    }

    if (!hasPlant) {
      return const _RealtimeTempComparison(
        status: "Tanaman belum dipilih",
        color: Colors.grey,
        detail: "Pilih tanaman aktif untuk evaluasi suhu",
      );
    }

    if (temp < minT) {
      return _RealtimeTempComparison(
        status: "Terlalu dingin",
        color: Colors.blue,
        detail:
            "${temp.toStringAsFixed(1)} C di bawah batas ${minT.toStringAsFixed(1)} C",
      );
    }
    if (temp > maxT) {
      return _RealtimeTempComparison(
        status: "Terlalu panas",
        color: Colors.red,
        detail:
            "${temp.toStringAsFixed(1)} C di atas batas ${maxT.toStringAsFixed(1)} C",
      );
    }

    return _RealtimeTempComparison(
      status: "Optimal",
      color: Colors.green,
      detail:
          "${temp.toStringAsFixed(1)} C dalam rentang ${minT.toStringAsFixed(1)}-${maxT.toStringAsFixed(1)} C",
    );
  }

  // ================= INIT =================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    deviceService = MqttDeviceService(
      deviceId: widget.deviceId,
      area: 'incubator',
    );
    controller = InkubatorController(
      deviceRepository: deviceService,
      plantRepository: deviceService,
    );
    controller.currentMode.value = deviceService.cachedMode;
    controller.hasActivePlant.value = deviceService.cachedActivePlantId.isNotEmpty;
    controller.init();

    ActivityLoggerService.log(
      action: 'screen.open',
      module: 'inkubator',
      deviceId: widget.deviceId,
      description: 'Membuka halaman inkubator (device: ${widget.deviceId})',
    );

    markDirty = () {
      if (mounted) setState(() {});
    };

    controller.timeNow.addListener(markDirty);
    controller.lampPWM.addListener(markDirty);
    controller.manualSprayerDuration.addListener(markDirty);
    controller.currentMode.addListener(markDirty);
    controller.hasActivePlant.addListener(markDirty);
    controller.minTemp.addListener(markDirty);
    controller.maxTemp.addListener(markDirty);
    controller.manualSprayerTimes.addListener(markDirty);
    controller.sprayerCountdown.addListener(markDirty);
    controller.autoLightPhaseInfo.addListener(markDirty);
    controller.plantAgeDays.addListener(markDirty);
    controller.darkPhaseDay.addListener(markDirty);
    controller.lightPhaseDay.addListener(markDirty);
    controller.currentPlantPhase.addListener(markDirty);
    controller.nextSprayerCountdownInfo.addListener(markDirty);
    _startChartStreams();
    unawaited(_loadChartHistory());
    _historyReloadTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_loadChartHistory()),
    );
  }

  // ================= DISPOSE =================

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tempChartSub?.cancel();
    _humChartSub?.cancel();
    _soilChartSub?.cancel();
    _historyReloadTimer?.cancel();
    _chartTick.dispose();
    controller.timeNow.removeListener(markDirty);
    controller.lampPWM.removeListener(markDirty);
    controller.manualSprayerDuration.removeListener(markDirty);
    controller.currentMode.removeListener(markDirty);
    controller.hasActivePlant.removeListener(markDirty);
    controller.minTemp.removeListener(markDirty);
    controller.maxTemp.removeListener(markDirty);
    controller.manualSprayerTimes.removeListener(markDirty);
    controller.sprayerCountdown.removeListener(markDirty);
    controller.autoLightPhaseInfo.removeListener(markDirty);
    controller.plantAgeDays.removeListener(markDirty);
    controller.darkPhaseDay.removeListener(markDirty);
    controller.lightPhaseDay.removeListener(markDirty);
    controller.currentPlantPhase.removeListener(markDirty);
    controller.nextSprayerCountdownInfo.removeListener(markDirty);
    controller.dispose();
    deviceService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadChartHistory());
    }
  }

  void _startChartStreams() {
    _tempChartSub = controller.deviceRepository.temperatureStream().listen((value) {
      _appendLiveChartSample(_temperatureHistory, value);
    });
    _humChartSub = controller.deviceRepository.humidityStream().listen((value) {
      _appendLiveChartSample(_humidityHistory, value);
    });
    _soilChartSub = controller.deviceRepository.soilMoistureStream().listen((value) {
      _appendLiveChartSample(_soilMoistureHistory, value);
    });
  }

  void _appendLiveChartSample(List<_ChartSample> target, double? value) {
    if (value == null) return;
    final now = DateTime.now();
    final x = now.millisecondsSinceEpoch.toDouble();
    final sample = _ChartSample(x: x, value: value, at: now);

    if (target.isNotEmpty) {
      final last = target.last;
      if (now.difference(last.at).inSeconds < 5) {
        target[target.length - 1] = sample;
      } else {
        target.add(sample);
      }
    } else {
      target.add(sample);
    }

    _trimChartToActiveRange(target);
    if (mounted) {
      _chartTick.value++;
    }
  }

  Future<void> _loadChartHistory() async {
    if (_historyReloading) return;
    _historyReloading = true;

    try {
      _chartError = null;
      final rawData = await MongoHistoryService.fetchRows(
        deviceId: widget.deviceId,
        measurement: 'incubator_sensor',
        fields: const <String>['temperature', 'humidity', 'soil_moisture'],
        rangeKey: _chartRangeKey,
      );

      final tempHistory = <_ChartSample>[];
      final humHistory = <_ChartSample>[];
      final soilHistory = <_ChartSample>[];

      for (final item in rawData) {
        final at = _parseMongoRowTime(item);
        if (at == null) continue;

        final tempRaw = item['temperature'];
        if (tempRaw is num) {
          tempHistory.add(_ChartSample(
            x: at.millisecondsSinceEpoch.toDouble(),
            value: tempRaw.toDouble(),
            at: at,
          ));
        }

        final humRaw = item['humidity'];
        if (humRaw is num) {
          humHistory.add(_ChartSample(
            x: at.millisecondsSinceEpoch.toDouble(),
            value: humRaw.toDouble(),
            at: at,
          ));
        }

        final soilRaw = item['soil_moisture'];
        if (soilRaw is num) {
          soilHistory.add(_ChartSample(
            x: at.millisecondsSinceEpoch.toDouble(),
            value: soilRaw.toDouble(),
            at: at,
          ));
        }
      }

      if (!mounted) return;
      tempHistory.sort((a, b) => a.at.compareTo(b.at));
      humHistory.sort((a, b) => a.at.compareTo(b.at));
      soilHistory.sort((a, b) => a.at.compareTo(b.at));
      _trimChartToActiveRange(tempHistory);
      _trimChartToActiveRange(humHistory);
      _trimChartToActiveRange(soilHistory);

      setState(() {
        _temperatureHistory
          ..clear()
          ..addAll(tempHistory);
        _humidityHistory
          ..clear()
          ..addAll(humHistory);
        _soilMoistureHistory
          ..clear()
          ..addAll(soilHistory);
        _chartTick.value++;
      });
    } on MongoHistoryException catch (error) {
      if (!mounted) return;
      setState(() {
        _chartError = error.message;
        _chartTick.value++;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _chartError = 'Histori MongoDB inkubator gagal dimuat.';
        _chartTick.value++;
      });
    } finally {
      _historyReloading = false;
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

  void _trimChartToActiveRange(List<_ChartSample> target) {
    if (target.isEmpty) return;
    final option = MongoHistoryService.rangeOptions[_chartRangeKey] ??
        MongoHistoryService.rangeOptions['15m']!;
    final cutoff = DateTime.now().subtract(Duration(minutes: option.minutes));
    target.removeWhere((sample) => sample.at.isBefore(cutoff));
    target.sort((a, b) => a.at.compareTo(b.at));
  }

  // ================= BUILD =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.green.shade900,
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Image.asset(
              "assets/logo/vitaroot.png",
              height: 28,
            ),
            const SizedBox(width: 10),
            const Text(
              "VitaRoot",
              style: TextStyle(
                color: Color.fromARGB(255, 255, 255, 255),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.greenAccent.shade400,
        child: const Icon(Icons.add, color: Color.fromARGB(255, 255, 255, 255)),
        onPressed: () {
          ActivityLoggerService.log(
            action: 'plant.open_add_form',
            module: 'inkubator',
            deviceId: widget.deviceId,
            description: 'Membuka form tambah tanaman baru pada device ${widget.deviceId}',
          );

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AddPlantPage(deviceId: widget.deviceId),
            ),
          );
        },
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1B5E20), Color(0xFF66BB6A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              /// HEADER
              SliverPersistentHeader(
                pinned: true,
                delegate: StickyHeaderDelegate(
                  height: 110,
                  child: Container(
                    color: Colors.green.shade800,
                    child: HeaderWidget(
                      // valueNotifier is updated by the controller; since
                      // we rebuild the widget tree on every tick we can just
                      // pass the current string value here.
                      timeSource: controller.timeNow.value,
                    ),
                  ),
                ),
              ),

              /// BODY
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                      _espLabelPanel(),
                      const SizedBox(height: 8),
                      _environmentOverviewPanel(),
                      const SizedBox(height: 8),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "Tap panel suhu, kelembapan, atau kelembapan tanah untuk melihat grafik MongoDB",
                          style: TextStyle(color: Color(0xFFD7EFD9), fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 16),
                      EspStatusCard(service: controller.deviceRepository),
                      const SizedBox(height: 16),
                      plantCard(),
                      if (controller.currentMode.value == "auto" &&
                          controller.hasActivePlant.value) ...[
                        const SizedBox(height: 12),
                        _activePlantMonitorPanel(),
                      ],
                      const SizedBox(height: 16),
                      modeCard(),
                      const SizedBox(height: 16),
                      relayCard(),
                      const SizedBox(height: 16),
                      autoLightCycleCard(),
                      const SizedBox(height: 16),
                      sprayerManualInput(),
                      const SizedBox(height: 16),
                      manualSprayerScheduleCard(),
                      lampSlider(),
                      const SizedBox(height: 16),
                      sprayerCountdownCard(),
                      const SizedBox(height: 100),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================= TEMPERATURE =================

  Widget temperatureWidget() {
    final lastTelemetry = MqttDeviceService.telemetryHistoryFor(widget.deviceId);
    final lastTemp = deviceService.cachedTemperature ??
        (lastTelemetry.isNotEmpty && lastTelemetry.last['temperature'] is num
            ? (lastTelemetry.last['temperature'] as num).toDouble()
            : null);
    return StreamBuilder<double?>(
      stream: controller.deviceRepository.temperatureStream(),
      initialData: lastTemp,
      builder: (context, snap) {
        final temp = snap.data ?? 0;
        final comparison = _buildRealtimeTempComparison(temp);

        return TemperatureCard(
          temp: temp,
          status: comparison.status,
          color: comparison.color,
          compact: true,
        );
      },
    );
  }

  // ================= HUMIDITY =================

  Widget humidityWidget() {
    final lastTelemetry = MqttDeviceService.telemetryHistoryFor(widget.deviceId);
    final lastHum = deviceService.cachedHumidity ??
        (lastTelemetry.isNotEmpty && lastTelemetry.last['humidity'] is num
            ? (lastTelemetry.last['humidity'] as num).toDouble()
            : null);
    return StreamBuilder<double?>(
      stream: controller.deviceRepository.humidityStream(),
      initialData: lastHum,
      builder: (context, snap) {
        final hum = snap.data ?? 0;
        return TemperatureCard(
          temp: hum,
          status: "Kelembapan",
          color: Colors.blue,
          unit: "%",
          icon: Icons.water_drop,
          compact: true,
        );
      },
    );
  }

  Widget _environmentOverviewPanel() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardGap = constraints.maxWidth >= 720 ? 14.0 : 12.0;
        final wide = constraints.maxWidth >= 980;
        final medium = constraints.maxWidth >= 620;
        final cards = <Widget>[
          _environmentCard(child: temperatureWidget()),
          _environmentCard(child: humidityWidget()),
          _environmentCard(child: soilMoistureWidget()),
        ];

        if (wide) {
          return Row(
            children: [
              Expanded(child: cards[0]),
              SizedBox(width: cardGap),
              Expanded(child: cards[1]),
              SizedBox(width: cardGap),
              Expanded(child: cards[2]),
            ],
          );
        }

        if (medium) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: cards[0]),
                  SizedBox(width: cardGap),
                  Expanded(child: cards[1]),
                ],
              ),
              SizedBox(height: cardGap),
              cards[2],
            ],
          );
        }

        return Column(
          children: [
            cards[0],
            SizedBox(height: cardGap),
            cards[1],
            SizedBox(height: cardGap),
            cards[2],
          ],
        );
      },
    );
  }

  Widget _environmentCard({required Widget child}) {
    return GestureDetector(
      onTap: _showEnvironmentChart,
      child: IndustrialCard(
        child: child,
      ),
    );
  }

  Widget soilMoistureWidget() {
    final lastTelemetry = MqttDeviceService.telemetryHistoryFor(widget.deviceId);
    final lastSoil = deviceService.cachedSoilMoisture ??
        (lastTelemetry.isNotEmpty && lastTelemetry.last['soil_moisture'] is num
            ? (lastTelemetry.last['soil_moisture'] as num).toDouble()
            : null);
    return StreamBuilder<double?>(
      stream: controller.deviceRepository.soilMoistureStream(),
      initialData: lastSoil,
      builder: (context, snap) {
        final soil = snap.data ?? 0;
        return TemperatureCard(
          temp: soil,
          status: "Kelembapan Tanah",
          color: Colors.lightGreenAccent,
          unit: "%",
          icon: Icons.grass_rounded,
          compact: true,
        );
      },
    );
  }

  // ================= PLANT CARD =================

  Widget plantCard() {
    return StreamBuilder<String>(
      stream: controller.deviceRepository.modeStream(),
      initialData: deviceService.cachedMode,
      builder: (context, modeSnap) {
        final currentMode =
            modeSnap.data ?? "manual";
        return StreamBuilder<String>(
          stream: controller.deviceRepository.activePlantStream(),
          initialData: deviceService.cachedActivePlantId,
          builder: (context, activeSnap) {
            final activePlantId =
                activeSnap.data ?? "";
            return StreamBuilder<Map<String, dynamic>>(
              stream: controller.plantRepository.plantStream(),
              builder: (context, snap) {
                final raw = snap.data;
                if (raw == null || raw.isEmpty) {
                  return const Card(
                    child: ListTile(
                      title: Text("Belum ada tanaman"),
                    ),
                  );
                }
                final map = raw;
                return IndustrialCard(
                  child: Column(
                    children: map.entries.map((e) {
                      final id = e.key;
                      final data = Map<String, dynamic>.from(e.value);
                      final active = id == activePlantId;
                      return PlantTile(
                        id: id,
                        data: data,
                        isActive: active,
                        enabled: currentMode == "auto",
                        onActivateToggle: currentMode == "auto"
                            ? () {
                                final willActivate = !active;
                                controller.deviceRepository
                                    .setActivePlant(active ? "" : id);
                                ActivityLoggerService.log(
                                  action: 'plant.activate',
                                  module: 'inkubator',
                                  deviceId: widget.deviceId,
                                  description: willActivate
                                      ? 'Mengaktifkan tanaman "$id" pada device ${widget.deviceId}'
                                      : 'Menonaktifkan tanaman "$id" pada device ${widget.deviceId}',
                                  metadata: {'plant_id': id, 'activated': willActivate},
                                );
                              }
                            : null,
                        onEdit: () async {
                          ActivityLoggerService.log(
                            action: 'plant.open_edit_form',
                            module: 'inkubator',
                            deviceId: widget.deviceId,
                            description: 'Membuka form edit tanaman "$id" pada device ${widget.deviceId}',
                            metadata: {'plant_id': id},
                          );
                          final updated = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AddPlantPage(
                                deviceId: widget.deviceId,
                                plantId: id,
                                plantData: data,
                              ),
                            ),
                          );
                          if (!context.mounted || updated != true) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Tanaman berhasil diperbarui"),
                            ),
                          );
                        },
                        onDelete: () async {
                          final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text("Hapus tanaman?"),
                                  content: Text(
                                    "Data tanaman \"$id\" akan dihapus permanen.",
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text("Batal"),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text("Hapus"),
                                    ),
                                  ],
                                ),
                              ) ??
                              false;
                          if (!confirmed || !context.mounted) return;

                          try {
                            await controller.plantRepository.deletePlant(id);
                            if (active) {
                              await controller.deviceRepository.setActivePlant("");
                            }
                            await ActivityLoggerService.log(
                              action: 'plant.delete',
                              module: 'inkubator',
                              deviceId: widget.deviceId,
                              description: 'Menghapus tanaman "$id" dari device ${widget.deviceId}',
                              metadata: {'plant_id': id, 'was_active': active},
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("Tanaman berhasil dihapus"),
                              ),
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text("Gagal menghapus tanaman: $e"),
                              ),
                            );
                          }
                        },
                      );
                    }).toList(),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
  // ================= MODE =================

  Widget modeCard() {
    return IndustrialCard(
      child: Row(
        children: [
          const Icon(
            Icons.auto_mode,
            color: Color(0xFF81C784),
          ),
          const SizedBox(width: 12),
          const Text(
            "Mode Otomatis",
            style: TextStyle(
              color: Color(0xFFE8F5E9),
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          StreamBuilder<String>(
            stream: controller.deviceRepository.modeStream(),
            initialData: deviceService.cachedMode,
            builder: (context, snap) {
              final auto = snap.data == "auto";

              return FlutterSwitch(
                width: 50,
                height: 26,
                value: auto,
                toggleSize: 22,
                activeColor: const Color(0xFF66BB6A),
                inactiveColor: Colors.white24,
                onToggle: (value) async {
                  await controller.deviceRepository.setMode(value);
                  final oldMode = value ? 'manual' : 'auto';
                  final newMode = value ? 'auto' : 'manual';
                  await ActivityLoggerService.log(
                    action: 'inkubator.mode.change',
                    module: 'inkubator',
                    deviceId: widget.deviceId,
                    description: 'Mode inkubator diubah dari $oldMode ke $newMode pada device ${widget.deviceId}',
                    metadata: {'old_mode': oldMode, 'new_mode': newMode},
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  // ================= RELAY =================

  Widget relayCard() {
    return IndustrialCard(
      child: Column(
        children: [
          relay("lamp", "Lampu", true),
          relay("fan", "Kipas", true),
          relay("sprayer", "Sprayer", true),
        ],
      ),
    );
  }

  Widget relay(String key, String label, bool enabled) {
    return StreamBuilder<bool>(
      stream: controller.deviceRepository.relayValueStream(key),
      initialData: deviceService.cachedRelayValue(key),
      builder: (context, snap) {
        final on = snap.data == true;
        return RelaySwitch(
          label: label,
          value: on,
          enabled: enabled,
          onChanged: (val) async {
            await controller.deviceRepository.setRelay(key, val);
            final stateLabel = val ? 'ON' : 'OFF';
            await ActivityLoggerService.log(
              action: 'inkubator.relay.toggle',
              module: 'inkubator',
              deviceId: widget.deviceId,
              description: 'User mengubah relay $label ($key) menjadi $stateLabel pada device ${widget.deviceId}',
              metadata: {'relay': key, 'relay_label': label, 'state': val},
            );
          },
        );
      },
    );
  }

  // ================= MANUAL SPRAYER =================

  Widget sprayerManualInput() {
    final duration = controller.manualSprayerDuration.value;
    final isManual = controller.currentMode.value == "manual";

    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// HEADER
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF81C784).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.timer_outlined,
                  color: Color(0xFF81C784),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  "Durasi Sprayer Manual",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE8F5E9),
                  ),
                ),
              ),
              Text(
                "$duration dtk",
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE8F5E9),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          /// SLIDER
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF66BB6A),
              inactiveTrackColor: Colors.white24,
              thumbColor: const Color(0xFF81C784),
              overlayColor: const Color(0xFF81C784).withOpacity(0.2),
              trackHeight: 4,
            ),
            child: Slider(
              value: duration.toDouble().clamp(1, 120),
              min: 1,
              max: 120,
              divisions: 119,
              label: "$duration detik",
              onChanged: isManual
                  ? (value) {
                      controller.setManualSprayerDuration(value.toInt());
                    }
                  : null,
            ),
          ),

          const SizedBox(height: 10),

          /// PRESET BUTTONS
          Wrap(
            spacing: 8,
            children: [
              _presetButton(5),
              _presetButton(10),
              _presetButton(30),
              _presetButton(60),
            ],
          ),
        ],
      ),
    );
  }

  Widget _presetButton(int value) {
    final current = controller.manualSprayerDuration.value;
    final selected = current == value;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: controller.currentMode.value != "manual"
          ? null
          : () => controller.setManualSprayerDuration(value),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF66BB6A)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          "$value dtk",
          style: TextStyle(
            color: selected
                ? const Color.fromARGB(255, 14, 14, 14)
                : const Color(0xFFE8F5E9),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // ================= PWM SLIDER =================

  Widget lampSlider() {
    final value = controller.lampPWM.value;
    final percent = value.round();

    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// HEADER
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.lightbulb_outline,
                  color: Colors.amber,
                  size: 20,
                ),
              ),

              const SizedBox(width: 12),

              const Expanded(
                child: Text(
                  "Kecerahan Lampu",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFF1F8E9),
                  ),
                ),
              ),

              /// VALUE BADGE
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF66BB6A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "$percent%",
                  style: const TextStyle(
                    color: Color.fromARGB(255, 249, 249, 249),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          /// SLIDER
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: const Color(0xFF66BB6A),
              inactiveTrackColor: Colors.white.withOpacity(0.15),
              thumbColor: const Color(0xFF81C784),
              overlayColor: const Color(0xFF81C784).withOpacity(0.2),
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 8,
              ),
              overlayShape: const RoundSliderOverlayShape(
                overlayRadius: 16,
              ),
            ),
            child: Slider(
              value: value,
              min: 0,
              max: 100,
              divisions: 10,
              label: "$percent%",
              onChanged: controller.setLampPWM,
            ),
          ),

          const SizedBox(height: 10),

          /// SCALE LABELS
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "0%",
                style: TextStyle(
                  color: Color(0xFFB0BEC5),
                  fontSize: 12,
                ),
              ),
              Text(
                "50%",
                style: TextStyle(
                  color: Color(0xFFB0BEC5),
                  fontSize: 12,
                ),
              ),
              Text(
                "100%",
                style: TextStyle(
                  color: Color(0xFFB0BEC5),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

// ================= MANUAL SPRAYER SCHEDULE =================

  Widget manualSprayerScheduleCard() {
    final mode = controller.currentMode.value;
    final times = controller.manualSprayerTimes.value;
    final isManual = mode == "manual";

    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// HEADER
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF81C784).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.schedule,
                  color: Color(0xFF81C784),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                "Jadwal Sprayer Manual",
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: Color(0xFFF1F8E9),
                ),
              ),
              const Spacer(),
              Text(
                "${times.length} jadwal",
                style: const TextStyle(
                  color: Color(0xFFB0BEC5),
                  fontSize: 13,
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          /// ADD BUTTON INDUSTRIAL STYLE
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: !isManual
                ? null
                : () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.now(),
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.dark(
                              primary: Color(0xFF66BB6A),
                              surface: Color(0xFF263238),
                            ),
                          ),
                          child: child!,
                        );
                      },
                    );

                    if (picked == null) return;

                    final newList = List<TimeOfDay>.from(times);
                    newList.add(picked);

                    await controller.saveManualSprayerTimes(newList);
                  },
            child: Container(
              padding: const EdgeInsets.symmetric(
                vertical: 12,
                horizontal: 14,
              ),
              decoration: BoxDecoration(
                color: isManual
                    ? const Color(0xFF66BB6A)
                    : Colors.grey.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_circle_outline,
                    color: Color.fromARGB(255, 255, 255, 255),
                    size: 18,
                  ),
                  SizedBox(width: 8),
                  Text(
                    "Tambah Waktu Siram",
                    style: TextStyle(
                      color: Color.fromARGB(255, 250, 250, 250),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          /// EMPTY STATE
          if (times.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              alignment: Alignment.center,
              child: const Text(
                "Belum ada jadwal",
                style: TextStyle(
                  color: Color(0xFFB0BEC5),
                  fontSize: 14,
                ),
              ),
            ),

          /// LIST TIMES
          ...times.asMap().entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: WateringTimeTile(
                    index: e.key,
                    time: e.value,
                    onEdit: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: e.value,
                      );

                      if (picked == null) return;

                      final newList = List<TimeOfDay>.from(times);
                      newList[e.key] = picked;

                      await controller.saveManualSprayerTimes(newList);
                    },
                    onDelete: () async {
                      final newList = List<TimeOfDay>.from(times);
                      newList.removeAt(e.key);

                      await controller.saveManualSprayerTimes(newList);
                    },
                  ),
                ),
              ),
        ],
      ),
    );
  }

// ================= COUNTDOWN CARD =================

  Widget sprayerCountdownCard() {
    final max = controller.manualSprayerDuration.value;
    final current = controller.sprayerCountdown.value;

    double progress = max == 0 ? 0 : current / max;

    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.timer_outlined,
                color: Color(0xFF81C784),
              ),
              const SizedBox(width: 10),
              const Text(
                "Countdown Sprayer",
                style: TextStyle(
                  color: Color(0xFFE8F5E9),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                "$current dtk",
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE8F5E9),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.white.withOpacity(0.1),
              valueColor: const AlwaysStoppedAnimation(
                Color(0xFF66BB6A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget autoLightCycleCard() {
    return IndustrialCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.wb_sunny_outlined,
            color: Color(0xFF81C784),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Siklus Lampu Otomatis",
                  style: TextStyle(
                    color: Color(0xFFE8F5E9),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  controller.autoLightPhaseInfo.value,
                  style: const TextStyle(
                    color: Color(0xFFC8E6C9),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _espLabelPanel() {
    return IndustrialCard(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _espTag('Page: Inkubator'),
          _espTag('ESP Controller + Monitoring'),
          _espTag('ESP: ${widget.deviceId}'),
          StreamBuilder<MqttConnectionState>(
            stream: MqttService.instance.connectionStream,
            builder: (context, snap) {
              final connected = snap.data == MqttConnectionState.connected
                  || MqttService.instance.isConnected;
              return _espTag(
                connected ? 'MQTT: Connected' : 'MQTT: Disconnected',
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _espTag(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFE8F5E9),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _activePlantMonitorPanel() {
    final phase = controller.currentPlantPhase.value;
    final currentTemp = deviceService.cachedTemperature ??
        (_temperatureHistory.isNotEmpty ? _temperatureHistory.last.value : null) ??
        0.0;
    final comparison = _buildRealtimeTempComparison(currentTemp);
    return IndustrialCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Monitor Tanaman Aktif",
            style: TextStyle(
              color: Color(0xFFE8F5E9),
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Usia tanaman di inkubator: hari ke-${controller.plantAgeDays.value}",
            style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            "Fase saat ini: $phase",
            style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            "Masa gelap: hari ke-${controller.darkPhaseDay.value == 0 ? '-' : controller.darkPhaseDay.value}",
            style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            "Masa terang: hari ke-${controller.lightPhaseDay.value == 0 ? '-' : controller.lightPhaseDay.value}",
            style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            controller.nextSprayerCountdownInfo.value,
            style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 13),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: comparison.color.withOpacity(0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: comparison.color.withOpacity(0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Perbandingan Suhu Realtime",
                  style: TextStyle(
                    color: comparison.color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  comparison.detail,
                  style: const TextStyle(
                    color: Color(0xFFE8F5E9),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showEnvironmentChart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F2D1A),
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.72,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
            child: ValueListenableBuilder<int>(
              valueListenable: _chartTick,
              builder: (context, _, __) {
                final tempSpots = _toSpots(_temperatureHistory);
                final humSpots = _toSpots(_humidityHistory);
                final soilSpots = _toSpots(_soilMoistureHistory);
                final visibleTempSpots =
                    tempSpots.where((spot) => !spot.isNull()).toList();
                final visibleHumSpots =
                    humSpots.where((spot) => !spot.isNull()).toList();
                final visibleSoilSpots =
                    soilSpots.where((spot) => !spot.isNull()).toList();
                final activeTitle = switch (_selectedChartMetric) {
                  'humidity' => 'Kelembapan (%)',
                  'soil_moisture' => 'Kelembapan Tanah (%)',
                  _ => 'Suhu (C)',
                };
                final activeColor = switch (_selectedChartMetric) {
                  'humidity' => const Color(0xFF4FC3F7),
                  'soil_moisture' => const Color(0xFF9CCC65),
                  _ => const Color(0xFFFF8A65),
                };
                final activeSpots = switch (_selectedChartMetric) {
                  'humidity' => humSpots,
                  'soil_moisture' => soilSpots,
                  _ => tempSpots,
                };
                final visibleActiveSpots = switch (_selectedChartMetric) {
                  'humidity' => visibleHumSpots,
                  'soil_moisture' => visibleSoilSpots,
                  _ => visibleTempSpots,
                };
                final axisRange = _chartAxisRange(visibleActiveSpots);
                final minX = axisRange.$1;
                final maxX = axisRange.$2;
                final showDots = visibleActiveSpots.length <= 2;
                final hasActiveData = visibleActiveSpots.isNotEmpty;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Grafik Lingkungan Inkubator",
                      style: TextStyle(
                        color: Color(0xFFE8F5E9),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _historyReloading
                          ? "Memuat histori MongoDB ${MongoHistoryService.rangeOptions[_chartRangeKey]?.label ?? 'aktif'}..."
                          : (_chartError ??
                              "Sumber data grafik: MongoDB | ${MongoHistoryService.rangeOptions[_chartRangeKey]?.label ?? ''}"),
                      style: TextStyle(
                        color: _chartError == null
                            ? const Color(0xFFA5D6A7)
                            : const Color(0xFFFFCC80),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Suhu'),
                          selected: _selectedChartMetric == 'temperature',
                          selectedColor: const Color(0xFF2E7D32),
                          backgroundColor: const Color(0x331A4A28),
                          side: const BorderSide(color: Color(0x55FFFFFF)),
                          labelStyle: TextStyle(
                            color: _selectedChartMetric == 'temperature'
                                ? Colors.white
                                : const Color(0xFFEAF8EF),
                            fontWeight: FontWeight.w700,
                          ),
                          onSelected: (_) {
                            setState(() {
                              _selectedChartMetric = 'temperature';
                            });
                            _chartTick.value++;
                          },
                        ),
                        ChoiceChip(
                          label: const Text('Kelembapan'),
                          selected: _selectedChartMetric == 'humidity',
                          selectedColor: const Color(0xFF2E7D32),
                          backgroundColor: const Color(0x331A4A28),
                          side: const BorderSide(color: Color(0x55FFFFFF)),
                          labelStyle: TextStyle(
                            color: _selectedChartMetric == 'humidity'
                                ? Colors.white
                                : const Color(0xFFEAF8EF),
                            fontWeight: FontWeight.w700,
                          ),
                          onSelected: (_) {
                            setState(() {
                              _selectedChartMetric = 'humidity';
                            });
                            _chartTick.value++;
                          },
                        ),
                        ChoiceChip(
                          label: const Text('Kelembapan Tanah'),
                          selected: _selectedChartMetric == 'soil_moisture',
                          selectedColor: const Color(0xFF2E7D32),
                          backgroundColor: const Color(0x331A4A28),
                          side: const BorderSide(color: Color(0x55FFFFFF)),
                          labelStyle: TextStyle(
                            color: _selectedChartMetric == 'soil_moisture'
                                ? Colors.white
                                : const Color(0xFFEAF8EF),
                            fontWeight: FontWeight.w700,
                          ),
                          onSelected: (_) {
                            setState(() {
                              _selectedChartMetric = 'soil_moisture';
                            });
                            _chartTick.value++;
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: MongoHistoryService.rangeOptions.entries.map((entry) {
                        final active = entry.key == _chartRangeKey;
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
                            if (_chartRangeKey == entry.key) return;
                            setState(() {
                              _chartRangeKey = entry.key;
                            });
                            _trimChartToActiveRange(_temperatureHistory);
                            _trimChartToActiveRange(_humidityHistory);
                            _trimChartToActiveRange(_soilMoistureHistory);
                            unawaited(_loadChartHistory());
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                        decoration: BoxDecoration(
                          color: const Color(0x332E7D32),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0x55FFFFFF)),
                        ),
                        child: _historyReloading
                            ? const Center(
                                child: CircularProgressIndicator(color: Color(0xFF9CCC65)),
                              )
                            : hasActiveData
                            ? _buildEnvironmentSeriesChart(
                                title: activeTitle,
                                color: activeColor,
                                spots: activeSpots,
                                visibleSpots: visibleActiveSpots,
                                minX: minX,
                                maxX: maxX,
                                showDots: showDots,
                                showBottomTitles: true,
                                showArea: true,
                              )
                            : Center(
                                child: Text(
                                  _chartError ?? "Belum ada data MongoDB pada rentang ini",
                                  style: const TextStyle(
                                    color: Color(0xFFC8E6C9),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Row(
                      children: [
                        _LegendDot(color: Color(0xFFFF8A65), label: "Suhu"),
                        SizedBox(width: 10),
                        _LegendDot(color: Color(0xFF4FC3F7), label: "Kelembapan"),
                        SizedBox(width: 10),
                        _LegendDot(color: Color(0xFF9CCC65), label: "Kelembapan Tanah"),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  List<FlSpot> _toSpots(List<_ChartSample> samples) {
    return samples.map((item) {
      if (item.value == null) return FlSpot.nullSpot;
      return FlSpot(item.x, item.value!);
    }).toList();
  }

  Widget _buildEnvironmentSeriesChart({
    required String title,
    required Color color,
    required List<FlSpot> spots,
    required List<FlSpot> visibleSpots,
    required double minX,
    required double maxX,
    required bool showDots,
    required bool showBottomTitles,
    bool showArea = false,
  }) {
    final values = visibleSpots.map((spot) => spot.y).toList();
    final minValue = values.isEmpty ? 0.0 : values.reduce(math.min);
    final maxValue = values.isEmpty ? 1.0 : values.reduce(math.max);
    final diff = (maxValue - minValue).abs();
    final padding = math.max(0.12, diff * 0.35);
    final minY = minValue - padding;
    final maxY = maxValue + padding;
    final yInterval = _niceInterval(maxY - minY);
    final yDigits = _yAxisDigits(maxY - minY);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: minY,
              maxY: maxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: true,
                horizontalInterval: yInterval,
                verticalInterval: _timeAxisInterval(minX, maxX),
                getDrawingHorizontalLine: (_) => const FlLine(
                  color: Colors.white12,
                  strokeWidth: 1,
                ),
                getDrawingVerticalLine: (_) => const FlLine(
                  color: Colors.white12,
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(
                show: true,
                border: Border.all(color: Colors.white24),
              ),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 34,
                    interval: yInterval,
                    getTitlesWidget: (value, meta) => Text(
                      value.toStringAsFixed(yDigits),
                      style: const TextStyle(
                        color: Color(0xFFC8E6C9),
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: showBottomTitles,
                    reservedSize: 28,
                    interval: _timeAxisInterval(minX, maxX),
                    getTitlesWidget: (value, meta) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _xToShortTimeLabel(value),
                        style: const TextStyle(
                          color: Color(0xFFC8E6C9),
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: color,
                  barWidth: 3,
                  dotData: FlDotData(show: showDots),
                  belowBarData: showArea
                      ? BarAreaData(
                          show: true,
                          gradient: LinearGradient(
                            colors: [
                              color.withOpacity(0.26),
                              color.withOpacity(0.03),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        )
                      : BarAreaData(show: false),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  double _niceInterval(double range) {
    if (range <= 0.5) return 0.1;
    if (range <= 1.5) return 0.2;
    if (range <= 4) return 0.5;
    if (range <= 8) return 1;
    if (range <= 20) return 2;
    return 10;
  }

  int _yAxisDigits(double range) {
    if (range <= 1.5) return 2;
    if (range <= 8) return 1;
    return 0;
  }

  double _timeAxisInterval(double minX, double maxX) {
    final span = maxX - minX;
    final hour = const Duration(hours: 1).inMilliseconds.toDouble();
    if (span <= const Duration(hours: 12).inMilliseconds) return hour * 2;
    if (span <= const Duration(days: 1).inMilliseconds) return hour * 6;
    if (span <= const Duration(days: 3).inMilliseconds) return hour * 12;
    return hour * 24;
  }

  (double, double) _chartAxisRange(List<FlSpot> spots) {
    final option = MongoHistoryService.rangeOptions[_chartRangeKey] ??
        MongoHistoryService.rangeOptions['15m']!;
    final rangeMs = Duration(minutes: option.minutes).inMilliseconds.toDouble();
    final nowX = DateTime.now().millisecondsSinceEpoch.toDouble();

    if (spots.isEmpty) {
      return (
        nowX - rangeMs,
        nowX,
      );
    }

    final lastX = math.max(spots.last.x, nowX);
    final startX = lastX - rangeMs;
    return (startX, lastX);
  }

  String _xToTimeLabel(double x) {
    final at = DateTime.fromMillisecondsSinceEpoch(x.round()).toLocal();
    return "${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}";
  }

  String _xToShortTimeLabel(double x) {
    final at = DateTime.fromMillisecondsSinceEpoch(x.round()).toLocal();
    final dd = at.day.toString().padLeft(2, '0');
    final mm = at.month.toString().padLeft(2, '0');
    final hh = at.hour.toString().padLeft(2, '0');
    final minute = at.minute.toString().padLeft(2, '0');
    return "$dd/$mm $hh:$minute";
  }
}

class _ChartSample {
  final double x;
  final double? value;
  final DateTime at;

  const _ChartSample({
    required this.x,
    required this.value,
    required this.at,
  });
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: Color(0xFFC8E6C9), fontSize: 11),
        ),
      ],
    );
  }
}

class _RealtimeTempComparison {
  final String status;
  final Color color;
  final String detail;

  const _RealtimeTempComparison({
    required this.status,
    required this.color,
    required this.detail,
  });
}

