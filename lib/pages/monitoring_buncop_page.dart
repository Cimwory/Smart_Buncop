import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../services/mqtt_device_service.dart';
import '../services/atc_enviro_mqtt_service.dart';
import '../services/atc_smart_hydroponic_mqtt_service.dart';
import '../services/atc_irrigation_mqtt_service.dart';
import '../services/activity_logger_service.dart';

class _Bc1ScreenHouseEspDefine {
  static const String deviceId = 'bc1_screenhouse';
  static const List<String> relayKeys = ['relay1', 'relay2', 'relay3'];
}

class MonitoringBuncopPage extends StatelessWidget {
  const MonitoringBuncopPage({super.key});

  static const List<_AreaConfig> _areas = [
    _AreaConfig(
      code: 'BC-1',
      title: 'Buncob 1',
      subtitle: 'Screen House',
      imageAsset: 'assets/area/bc1.jpg',
      points: [
        _MonitoringPoint(
          name: 'Screen House',
          deviceId: _Bc1ScreenHouseEspDefine.deviceId,
        ),
      ],
    ),
    _AreaConfig(
      code: 'BC-2',
      title: 'Buncob 2',
      subtitle: 'Hidroponik, Rumah Kaca Anggrek, Screen House',
      imageAsset: 'assets/area/bc2.jpg',
      points: [],
    ),
    _AreaConfig(
      code: 'ATC',
      title: 'Agro Tech Center',
      subtitle: 'Enviro Control',
      imageAsset: 'assets/area/atc.jpg',
      points: [
        _MonitoringPoint(
          name: 'Enviro Control',
          deviceId: 'atc_enviro',
          kind: _MonitoringPointKind.atcEnviro,
        ),
        _MonitoringPoint(
          name: 'Smart Hidroponik',
          deviceId: 'atc_smart_hidroponik',
          kind: _MonitoringPointKind.atcSmartHydroponic,
        ),
        _MonitoringPoint(
          name: 'Irigasi RKK',
          deviceId: 'atc_irigasi_rkk',
          kind: _MonitoringPointKind.atcIrrigation,
        ),
        _MonitoringPoint(
          name: 'Irigasi RKB',
          deviceId: 'atc_irigasi_rkb',
          kind: _MonitoringPointKind.atcIrrigation,
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.green.shade900,
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Image.asset("assets/logo/vitaroot.png", height: 26),
            const SizedBox(width: 10),
            const Text(
              'Monitoring Area',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          const _PageBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _HeroInfoCard(),
                  const SizedBox(height: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide = constraints.maxWidth >= 780;
                        return GridView.builder(
                          itemCount: _areas.length,
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: isWide ? 2 : 1,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: isWide ? 1.68 : 1.95,
                          ),
                          itemBuilder: (context, index) {
                            final area = _areas[index];
                          return _AreaCard(
                            area: area,
                            onTap: () {
                              ActivityLoggerService.log(
                                action: 'monitoring.area.open',
                                module: 'monitoring',
                                description: 'Membuka area monitoring ${area.code} (${area.title})',
                                metadata: {'area_code': area.code, 'area_name': area.title},
                              );
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => _MonitoringAreaPage(area: area),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
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
}

class _MonitoringAreaPage extends StatefulWidget {
  final _AreaConfig area;

  const _MonitoringAreaPage({required this.area});

  @override
  State<_MonitoringAreaPage> createState() => _MonitoringAreaPageState();
}

class _MonitoringAreaPageState extends State<_MonitoringAreaPage> {
  List<Widget> _buildPointSection() {
    if (widget.area.code == 'BC-1' && widget.area.points.isNotEmpty) {
      return [
        _ScreenHouseValveControlCard(point: widget.area.points.first),
      ];
    }

    if (widget.area.code == 'ATC') {
      return widget.area.points.map((point) {
        switch (point.kind) {
          case _MonitoringPointKind.atcEnviro:
            return _AtcEnviroControlCard(point: point);
          case _MonitoringPointKind.atcSmartHydroponic:
            return _AtcSmartHydroponicControlCard(point: point);
          case _MonitoringPointKind.atcIrrigation:
            return _AtcIrrigationControlCard(point: point);
          case _MonitoringPointKind.standard:
            return _MonitoringPointCard(point: point);
        }
      }).toList();
    }

    return widget.area.points
        .map((point) => _MonitoringPointCard(point: point))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    ActivityLoggerService.log(
      action: 'monitoring.area.view',
      module: 'monitoring',
      description: 'Melihat detail area ${widget.area.code} (${widget.area.title}) dengan ${widget.area.points.length} titik monitoring',
      metadata: {
        'area_code': widget.area.code,
        'area_name': widget.area.title,
        'point_count': widget.area.points.length,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.green.shade900,
        foregroundColor: Colors.white,
        title: Text('Monitoring ${widget.area.code}'),
      ),
      body: Stack(
        children: [
          const _PageBackground(),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.area.code} - ${widget.area.title}',
                        style: const TextStyle(
                          color: Color(0xFFF1F8E9),
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        widget.area.subtitle,
                        style: const TextStyle(
                          color: Color(0xFFD7EFD9),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _ChipLabel(label: 'Titik: ${widget.area.points.length}'),
                          const _ChipLabel(label: 'ESP Monitoring'),
                          if (widget.area.code != 'ATC')
                            const _ChipLabel(label: 'Realtime MQTT'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ..._buildPointSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AreaCard extends StatelessWidget {
  final _AreaConfig area;
  final VoidCallback onTap;

  const _AreaCard({
    required this.area,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: const Color(0xB0123323),
              border: Border.all(color: const Color(0x66FFFFFF)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _AreaImageSlot(imageAsset: area.imageAsset),
                          Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Color(0x00000000), Color(0xB3000000)],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 10,
                            bottom: 10,
                            child: _ChipLabel(label: area.code),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    area.title,
                    style: const TextStyle(
                      color: Color(0xFFF1F8E9),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          area.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFC8E6C9),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        size: 20,
                        color: Color(0xFFB9E5BE),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AreaImageSlot extends StatelessWidget {
  final String? imageAsset;

  const _AreaImageSlot({required this.imageAsset});

  @override
  Widget build(BuildContext context) {
    if (imageAsset != null && imageAsset!.isNotEmpty) {
      return Image.asset(imageAsset!, fit: BoxFit.cover);
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0x884CAF50), Color(0x333C8D40)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined, color: Color(0xFFE8F5E9), size: 28),
            SizedBox(height: 6),
            Text(
              'Tambahkan gambar area',
              style: TextStyle(
                color: Color(0xFFD7EFD9),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonitoringPointCard extends StatefulWidget {
  final _MonitoringPoint point;

  const _MonitoringPointCard({required this.point});

  @override
  State<_MonitoringPointCard> createState() => _MonitoringPointCardState();
}

class _MonitoringPointCardState extends State<_MonitoringPointCard> {
  late final MqttDeviceService _service;

  @override
  void initState() {
    super.initState();
    _service = MqttDeviceService(deviceId: widget.point.deviceId, area: 'monitoring');
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          ActivityLoggerService.log(
            action: 'monitoring.node.inspect',
            module: 'monitoring',
            deviceId: widget.point.deviceId,
            description: 'Inspect node "${widget.point.name}" (device: ${widget.point.deviceId})',
            metadata: {'node_name': widget.point.name},
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    widget.point.name,
                    style: const TextStyle(
                      color: Color(0xFFF1F8E9),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                StreamBuilder<bool>(
                  stream: _service.espOnlineStream(),
                  builder: (context, snapshot) {
                    final online = snapshot.data ?? false;
                    return _StatusPill(online: online);
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                const _ChipLabel(label: 'Monitoring Titik'),
                _ChipLabel(label: 'Device: ${widget.point.deviceId}'),
              ],
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 420;
                if (isNarrow) {
                  return Column(
                    children: [
                      _MetricTile(
                        label: 'Suhu',
                        unit: 'C',
                        icon: Icons.thermostat,
                        stream: _service.temperatureStream(),
                      ),
                      const SizedBox(height: 8),
                      _MetricTile(
                        label: 'Kelembapan',
                        unit: '%',
                        icon: Icons.water_drop,
                        stream: _service.humidityStream(),
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(
                      child: _MetricTile(
                        label: 'Suhu',
                        unit: 'C',
                        icon: Icons.thermostat,
                        stream: _service.temperatureStream(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MetricTile(
                        label: 'Kelembapan',
                        unit: '%',
                        icon: Icons.water_drop,
                        stream: _service.humidityStream(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ScreenHouseValveControlCard extends StatefulWidget {
  final _MonitoringPoint point;

  const _ScreenHouseValveControlCard({required this.point});

  @override
  State<_ScreenHouseValveControlCard> createState() =>
      _ScreenHouseValveControlCardState();
}

class _ScreenHouseValveControlCardState extends State<_ScreenHouseValveControlCard> {
  static const List<String> _relayKeys = _Bc1ScreenHouseEspDefine.relayKeys;
  late final MqttDeviceService _fbService;
  String _selectedChartMetric = 'temperature';

  @override
  void initState() {
    super.initState();
    _fbService = MqttDeviceService(deviceId: widget.point.deviceId, area: 'monitoring');
  }

  @override
  void dispose() {
    _fbService.dispose();
    super.dispose();
  }

  Future<void> _setAllRelays(bool value) async {
    await Future.wait(_relayKeys.map((key) => _fbService.setRelay(key, value)));
    final stateLabel = value ? 'ON' : 'OFF';
    await ActivityLoggerService.log(
      action: 'monitoring.bc1.valve.toggle_all',
      module: 'monitoring',
      deviceId: widget.point.deviceId,
      description: 'Toggle manual semua valve (${_relayKeys.join(", ")}) menjadi $stateLabel pada device ${widget.point.deviceId}',
      metadata: {'state': value, 'relays': _relayKeys},
    );
  }

  List<TimeOfDay> _decodeTimes(dynamic raw) {
    final values = <String>[];

    if (raw is List) {
      for (final item in raw) {
        if (item == null) continue;
        values.add(item.toString());
      }
    } else if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final entries = map.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key) ?? 0;
          final bi = int.tryParse(b.key) ?? 0;
          return ai.compareTo(bi);
        });
      for (final entry in entries) {
        values.add(entry.value.toString());
      }
    }

    final result = <TimeOfDay>[];
    for (final value in values) {
      final parts = value.split(':');
      if (parts.length < 2) continue;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null) continue;
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) continue;
      result.add(TimeOfDay(hour: hour, minute: minute));
    }

    return result;
  }

  String _formatTime(TimeOfDay time) {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Future<void> _saveTimes(
    MqttDeviceService service,
    List<TimeOfDay> times,
  ) async {
    final mapped = <String, String>{};
    for (var i = 0; i < times.length; i++) {
      mapped['$i'] = _formatTime(times[i]);
    }
    await service.setManualSprayerTimes(mapped);
    await ActivityLoggerService.log(
      action: 'monitoring.bc1.valve.schedule.save',
      module: 'monitoring',
      deviceId: widget.point.deviceId,
      description: 'Menyimpan ${mapped.length} jadwal valve otomatis pada device ${widget.point.deviceId}: ${mapped.values.join(", ")}',
      metadata: {'times': mapped.values.toList(), 'count': mapped.length},
    );
  }

  Widget _buildMetricRow() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 420;
        final suhu = _MetricTile(
          label: 'Suhu', unit: 'C', icon: Icons.thermostat,
          stream: _fbService.temperatureStream(),
        );
        final hum = _MetricTile(
          label: 'Kelembapan', unit: '%', icon: Icons.water_drop,
          stream: _fbService.humidityStream(),
        );
        if (isNarrow) {
          return Column(children: [suhu, const SizedBox(height: 8), hum]);
        }
        return Row(children: [
          Expanded(child: suhu), const SizedBox(width: 8), Expanded(child: hum),
        ]);
      },
    );
  }

  List<FlSpot> _screenHouseChartSpots(String metric) {
    final history = MqttDeviceService.telemetryHistoryFor(widget.point.deviceId);
    final spots = <FlSpot>[];
    var x = 0.0;
    for (final row in history) {
      final raw = row[metric];
      if (raw is num) {
        spots.add(FlSpot(x, raw.toDouble()));
        x += 1.0;
      }
    }
    return spots;
  }

  Widget _buildRealtimeChartSection() {
    final options = <String, ({String label, String unit, Color color})>{
      'temperature': (label: 'Suhu', unit: 'C', color: const Color(0xFFFFB74D)),
      'humidity': (label: 'Kelembapan', unit: '%', color: const Color(0xFF4FC3F7)),
    };
    final selected = options[_selectedChartMetric] ?? options['temperature']!;

    return StreamBuilder<double?>(
      stream: _fbService.temperatureStream(),
      builder: (context, _) {
        return StreamBuilder<double?>(
          stream: _fbService.humidityStream(),
          builder: (context, __) {
            final spots = _screenHouseChartSpots(_selectedChartMetric);
            return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Chart Realtime Monitoring',
            style: TextStyle(
              color: Color(0xFFE8F5E9),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: options.entries.map((entry) {
              final active = _selectedChartMetric == entry.key;
              return ChoiceChip(
                label: Text(entry.value.label),
                selected: active,
                selectedColor: const Color(0xFF2E7D32),
                backgroundColor: const Color(0x221A4A28),
                side: const BorderSide(color: Color(0x44FFFFFF)),
                labelStyle: TextStyle(
                  color: active ? const Color(0xFFF1F8E9) : const Color(0xFFD7EFD9),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                onSelected: (_) => setState(() => _selectedChartMetric = entry.key),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          _MiniRealtimeChart(
            title: selected.label,
            unit: selected.unit,
            color: selected.color,
            spots: spots,
            emptyMessage: 'Menunggu telemetry realtime...',
          ),
        ],
      ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  widget.point.name,
                  style: const TextStyle(
                    color: Color(0xFFF1F8E9),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              StreamBuilder<bool>(
                      stream: _fbService.espOnlineStream(),
                      builder: (context, snapshot) {
                        final online = snapshot.data ?? false;
                        return _StatusPill(online: online);
                      },
                    ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              const _ChipLabel(label: 'Monitoring Valve'),
              _ChipLabel(label: 'Device: ${widget.point.deviceId}'),
              const _ChipLabel(label: '3 Kanal'),
            ],
          ),
          const SizedBox(height: 10),
          _buildMetricRow(),
          const SizedBox(height: 8),
          _buildRealtimeChartSection(),
          const SizedBox(height: 10),
          _buildModeSection(),
        ],
      ),
    );
  }

  Widget _buildModeSection() {
    return StreamBuilder<String>(
      stream: _fbService.modeStream(),
      builder: (context, modeSnapshot) {
        final autoMode = modeSnapshot.data == 'auto';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0x332E7D32),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x55FFFFFF)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_mode, color: Color(0xFFB9E5BE), size: 18),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Mode Otomatis Valve',
                            style: TextStyle(
                              color: Color(0xFFE8F5E9),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: autoMode,
                          activeColor: const Color(0xFF66BB6A),
                          onChanged: (value) async {
                            await _fbService.setMode(value);
                            if (value) {
                              await Future.wait(
                                _relayKeys.map((key) => _fbService.setRelay(key, false)),
                              );
                            }
                            await ActivityLoggerService.log(
                              action: 'monitoring.bc1.valve.mode.change',
                              module: 'monitoring',
                              deviceId: widget.point.deviceId,
                              description: 'Mode valve diubah dari ${value ? "manual" : "auto"} ke ${value ? "auto" : "manual"} pada device ${widget.point.deviceId}',
                              metadata: {'old_mode': value ? 'manual' : 'auto', 'new_mode': value ? 'auto' : 'manual'},
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (!autoMode) ...[
                    StreamBuilder<bool>(
                      stream: _fbService.relayValueStream(_relayKeys[0]),
                      builder: (context, relay1) {
                        final r1 = relay1.data ?? false;
                        return StreamBuilder<bool>(
                          stream: _fbService.relayValueStream(_relayKeys[1]),
                          builder: (context, relay2) {
                            final r2 = relay2.data ?? false;
                            return StreamBuilder<bool>(
                              stream: _fbService.relayValueStream(_relayKeys[2]),
                              builder: (context, relay3) {
                                final r3 = relay3.data ?? false;
                                final anyOn = r1 || r2 || r3;
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0x332E7D32),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0x55FFFFFF)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.tune, color: Color(0xFFB9E5BE), size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Manual Valve (Relay 1-3)',
                                              style: TextStyle(
                                                color: Color(0xFFE8F5E9),
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Text(
                                              'R1:${r1 ? 'ON' : 'OFF'}  R2:${r2 ? 'ON' : 'OFF'}  R3:${r3 ? 'ON' : 'OFF'}',
                                              style: const TextStyle(
                                                color: Color(0xFFD7EFD9),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Switch.adaptive(
                                        value: anyOn,
                                        activeColor: const Color(0xFF66BB6A),
                                        onChanged: (value) async {
                                          await _setAllRelays(value);
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
                  ] else ...[
                    StreamBuilder<int?>(
                      stream: _fbService.sprayerDurationStream(),
                      builder: (context, durationSnapshot) {
                        final duration = durationSnapshot.data ?? 10;
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0x332E7D32),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0x55FFFFFF)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.timer_outlined, color: Color(0xFFB9E5BE), size: 18),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Durasi Buka Valve',
                                      style: TextStyle(
                                        color: Color(0xFFE8F5E9),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$duration dtk',
                                    style: const TextStyle(
                                      color: Color(0xFFE8F5E9),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _InlineInputButton(
                                    onPressed: () async {
                                      final value = await _showNumberInputDialog(
                                        context,
                                        title: 'Durasi Buka Valve (detik)',
                                        value: duration.toDouble(),
                                        min: 0,
                                        max: 120,
                                        decimals: 0,
                                      );
                                      if (value == null) return;
                                      await _fbService.setManualSprayerDuration(value.toInt());
                                      await ActivityLoggerService.log(
                                        action: 'monitoring.bc1.valve.duration.change',
                                        module: 'monitoring',
                                        deviceId: widget.point.deviceId,
                                        description:
                                            'Durasi valve otomatis diubah menjadi ${value.toInt()} detik pada device ${widget.point.deviceId}',
                                        metadata: {'duration_seconds': value.toInt()},
                                      );
                                    },
                                    label: 'Input',
                                  ),
                                ],
                              ),
                              Slider(
                                value: duration.toDouble().clamp(0, 120).toDouble(),
                                min: 0,
                                max: 120,
                                divisions: 120,
                                label: '$duration detik',
                                activeColor: const Color(0xFF66BB6A),
                                onChanged: (value) async {
                                  await _fbService.setManualSprayerDuration(value.toInt());
                                  await ActivityLoggerService.log(
                                    action: 'monitoring.bc1.valve.duration.change',
                                    module: 'monitoring',
                                    deviceId: widget.point.deviceId,
                                    description: 'Durasi valve otomatis diubah menjadi ${value.toInt()} detik pada device ${widget.point.deviceId}',
                                    metadata: {'duration_seconds': value.toInt()},
                                  );
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<Map<String, String>>(
                      stream: _fbService.manualSprayerTimesStream(),
                      builder: (context, timesSnapshot) {
                        final times = _decodeTimes(timesSnapshot.data);
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0x332E7D32),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0x55FFFFFF)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.schedule, color: Color(0xFFB9E5BE), size: 18),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Jadwal Buka Valve (Auto)',
                                      style: TextStyle(
                                        color: Color(0xFFE8F5E9),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () async {
                                      final picked = await showTimePicker(
                                        context: context,
                                        initialTime: TimeOfDay.now(),
                                      );
                                      if (picked == null) return;
                                      final next = List<TimeOfDay>.from(times)..add(picked);
                                      await ActivityLoggerService.log(
                                        action: 'monitoring.bc1.valve.schedule.add_time',
                                        module: 'monitoring',
                                        deviceId: widget.point.deviceId,
                                        description:
                                            'Menambahkan jam valve otomatis ${_formatTime(picked)} pada device ${widget.point.deviceId}',
                                        metadata: {'time': _formatTime(picked)},
                                      );
                                      await _saveTimes(_fbService, next);
                                    },
                                    icon: const Icon(Icons.add, size: 16),
                                    label: const Text('Tambah'),
                                  ),
                                ],
                              ),
                              if (times.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Belum ada jadwal otomatis.',
                                    style: TextStyle(
                                      color: Color(0xFFD7EFD9),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ...times.asMap().entries.map((entry) {
                                final idx = entry.key;
                                final time = entry.value;
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    _formatTime(time),
                                    style: const TextStyle(
                                      color: Color(0xFFE8F5E9),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  leading: const Icon(
                                    Icons.alarm,
                                    color: Color(0xFFB9E5BE),
                                    size: 18,
                                  ),
                                  trailing: Wrap(
                                    spacing: 6,
                                    children: [
                                      IconButton(
                                        tooltip: 'Ubah waktu',
                                        onPressed: () async {
                                          final picked = await showTimePicker(
                                            context: context,
                                            initialTime: time,
                                          );
                                          if (picked == null) return;
                                          final next = List<TimeOfDay>.from(times);
                                          next[idx] = picked;
                                          await ActivityLoggerService.log(
                                            action: 'monitoring.bc1.valve.schedule.edit_time',
                                            module: 'monitoring',
                                            deviceId: widget.point.deviceId,
                                            description:
                                                'Mengubah jam valve otomatis dari ${_formatTime(time)} ke ${_formatTime(picked)} pada device ${widget.point.deviceId}',
                                            metadata: {
                                              'old_time': _formatTime(time),
                                              'new_time': _formatTime(picked),
                                            },
                                          );
                                          await _saveTimes(_fbService, next);
                                        },
                                        icon: const Icon(Icons.edit_outlined, size: 18),
                                      ),
                                      IconButton(
                                        tooltip: 'Hapus waktu',
                                        onPressed: () async {
                                          final removed = _formatTime(time);
                                          final next = List<TimeOfDay>.from(times)
                                            ..removeAt(idx);
                                          await ActivityLoggerService.log(
                                            action: 'monitoring.bc1.valve.schedule.remove_time',
                                            module: 'monitoring',
                                            deviceId: widget.point.deviceId,
                                            description:
                                                'Menghapus jam valve otomatis $removed pada device ${widget.point.deviceId}',
                                            metadata: {'time': removed},
                                          );
                                          await _saveTimes(_fbService, next);
                                        },
                                        icon: const Icon(Icons.delete_outline, size: 18),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ],
              );
            },
          );
  }
}

class _AtcEnviroControlCard extends StatefulWidget {
  final _MonitoringPoint point;

  const _AtcEnviroControlCard({required this.point});

  @override
  State<_AtcEnviroControlCard> createState() => _AtcEnviroControlCardState();
}

class _AtcEnviroControlCardState extends State<_AtcEnviroControlCard> {
  late final AtcEnviroMqttService _service;
  double _upperLimit = 25;
  double _lowerLimit = 10;
  double _r0Mq135 = 100;
  double _r0Mq2 = 2;

  @override
  void initState() {
    super.initState();
    _service = AtcEnviroMqttService(deviceId: widget.point.deviceId, area: 'monitoring');
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _saveLimits() async {
    final upper = _upperLimit.clamp(1, 500).toDouble();
    final lower = _lowerLimit.clamp(0, upper - 0.5).toDouble();
    _lowerLimit = lower;
    await _service.setNh3Limits(upper: upper, lower: lower);
    await ActivityLoggerService.log(
      action: 'monitoring.atc.limit.update',
      module: 'monitoring',
      deviceId: widget.point.deviceId,
      description:
          'Batas NH3 ${widget.point.name} diubah (upper=${upper.toStringAsFixed(2)}, lower=${lower.toStringAsFixed(2)})',
      metadata: {'nh3_upper_limit': upper, 'nh3_lower_limit': lower},
    );
  }

  Future<void> _saveCalibrationR0({
    required bool isMq135,
    required double value,
  }) async {
    final safe = value.clamp(0.0001, 100000).toDouble();
    if (isMq135) {
      _r0Mq135 = safe;
      await _service.setR0Mq135(safe);
    } else {
      _r0Mq2 = safe;
      await _service.setR0Mq2(safe);
    }
    await ActivityLoggerService.log(
      action: 'monitoring.atc.calibration.r0.update',
      module: 'monitoring',
      deviceId: widget.point.deviceId,
      description:
          'Set ${isMq135 ? "Cal Amonia (R0 MQ135)" : "Cal Metana (R0 MQ2)"} ATC ${widget.point.name} ke ${safe.toStringAsFixed(4)}',
      metadata: {
        'sensor': isMq135 ? 'mq135' : 'mq2',
        'r0_value': safe,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.point.name,
                      style: const TextStyle(
                        color: Color(0xFFF1F8E9),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ATC Enviro Control',
                      style: const TextStyle(
                        color: Color(0xFFD7EFD9),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              StreamBuilder<bool>(
                stream: _service.onlineStream(),
                builder: (context, snap) {
                  return _StatusPill(online: snap.data ?? false);
                },
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Color(0xFFE8F5E9)),
                onSelected: (value) async {
                  if (value == 'refresh') {
                    await _service.requestStatus();
                  } else if (value == 'manual_off') {
                    await _service.setMode(false);
                    await _service.setRelay(false);
                  } else if (value == 'auto') {
                    await _service.setMode(true);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'refresh', child: Text('Refresh Status')),
                  PopupMenuItem(value: 'manual_off', child: Text('Manual + Relay OFF')),
                  PopupMenuItem(value: 'auto', child: Text('Paksa Mode AUTO')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 420;
              final nh3 = _MetricTile(
                label: 'NH3',
                unit: 'ppm',
                icon: Icons.biotech,
                stream: _service.nh3Stream(),
              );
              final ch4 = _MetricTile(
                label: 'CH4',
                unit: 'ppm',
                icon: Icons.local_fire_department,
                stream: _service.methaneStream(),
              );
              if (isNarrow) {
                return Column(
                  children: [nh3, const SizedBox(height: 8), ch4],
                );
              }
              return Row(
                children: [
                  Expanded(child: nh3),
                  const SizedBox(width: 8),
                  Expanded(child: ch4),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<String>(
            stream: _service.systemMessageStream(),
            builder: (context, snap) {
              final text = (snap.data ?? 'System message: -').trim();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x332E7D32),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x55FFFFFF)),
                ),
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Color(0xFFE8F5E9),
                    fontSize: 11,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<String>(
            stream: _service.modeStream(),
            builder: (context, modeSnap) {
              final mode = (modeSnap.data ?? 'manual').toLowerCase();
              final autoMode = mode == 'auto';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x332E7D32),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x55FFFFFF)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Mode Otomatis NH3',
                            style: TextStyle(
                              color: Color(0xFFE8F5E9),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: autoMode,
                          activeColor: const Color(0xFF66BB6A),
                          onChanged: (value) async {
                            await _service.setMode(value);
                            await ActivityLoggerService.log(
                              action: 'monitoring.atc.mode.change',
                              module: 'monitoring',
                              deviceId: widget.point.deviceId,
                              description:
                                  'Mode ATC ${widget.point.name} diubah ke ${value ? "auto" : "manual"}',
                              metadata: {'mode': value ? 'auto' : 'manual'},
                            );
                          },
                        ),
                      ],
                    ),
                    if (!autoMode)
                      StreamBuilder<bool>(
                        stream: _service.relayStream(),
                        builder: (context, relaySnap) {
                          final relayOn = relaySnap.data ?? false;
                          return Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Relay Manual',
                                  style: TextStyle(
                                    color: Color(0xFFE8F5E9),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Switch.adaptive(
                                value: relayOn,
                                activeColor: const Color(0xFF66BB6A),
                                onChanged: (value) async {
                                  await _service.setRelay(value);
                                  await ActivityLoggerService.log(
                                    action: 'monitoring.atc.relay.toggle',
                                    module: 'monitoring',
                                    deviceId: widget.point.deviceId,
                                    description:
                                        'Relay manual ${widget.point.name} diubah ke ${value ? "ON" : "OFF"}',
                                    metadata: {'relay': value},
                                  );
                                },
                              ),
                            ],
                          );
                        },
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<double?>(
            stream: _service.nh3UpperLimitStream(),
            builder: (context, upSnap) {
              final upper = (upSnap.data ?? _upperLimit).clamp(1, 500).toDouble();
              if ((upper - _upperLimit).abs() > 0.001) {
                _upperLimit = upper;
              }
              return StreamBuilder<double?>(
                stream: _service.nh3LowerLimitStream(),
                builder: (context, lowSnap) {
                  final lowerRaw = (lowSnap.data ?? _lowerLimit).toDouble();
                  final lower = lowerRaw.clamp(0, upper - 0.5).toDouble();
                  if ((lower - _lowerLimit).abs() > 0.001) {
                    _lowerLimit = lower;
                  }

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0x332E7D32),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x55FFFFFF)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Batas NH3 (Upper: ${upper.toStringAsFixed(1)} | Lower: ${lower.toStringAsFixed(1)})',
                                style: const TextStyle(
                                  color: Color(0xFFE8F5E9),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            _InlineInputButton(
                              onPressed: () async {
                                final value = await _showNumberInputDialog(
                                  context,
                                  title: 'NH3 Upper Limit',
                                  value: _upperLimit,
                                  min: 1,
                                  max: 500,
                                  decimals: 1,
                                );
                                if (value == null) return;
                                setState(() {
                                  _upperLimit = value;
                                  if (_lowerLimit >= _upperLimit) {
                                    _lowerLimit = _upperLimit - 0.5;
                                  }
                                });
                                await _saveLimits();
                              },
                              label: 'Input Upper',
                            ),
                            _InlineInputButton(
                              onPressed: () async {
                                final maxLower = (_upperLimit - 0.5).clamp(0.5, 499).toDouble();
                                final value = await _showNumberInputDialog(
                                  context,
                                  title: 'NH3 Lower Limit',
                                  value: _lowerLimit,
                                  min: 0,
                                  max: maxLower,
                                  decimals: 1,
                                );
                                if (value == null) return;
                                setState(() => _lowerLimit = value.clamp(0, maxLower));
                                await _saveLimits();
                              },
                              label: 'Input Lower',
                            ),
                          ],
                        ),
                        Slider(
                          value: _upperLimit.clamp(1, 500).toDouble(),
                          min: 1,
                          max: 500,
                          divisions: 499,
                          label: 'Upper ${_upperLimit.toStringAsFixed(1)}',
                          activeColor: const Color(0xFF81C784),
                          onChanged: (value) {
                            setState(() {
                              _upperLimit = value;
                              if (_lowerLimit >= _upperLimit) {
                                _lowerLimit = _upperLimit - 0.5;
                              }
                            });
                          },
                          onChangeEnd: (_) => _saveLimits(),
                        ),
                        Slider(
                          value: _lowerLimit.clamp(0, (_upperLimit - 0.5).clamp(0.5, 499)).toDouble(),
                          min: 0,
                          max: (_upperLimit - 0.5).clamp(0.5, 499).toDouble(),
                          divisions: 500,
                          label: 'Lower ${_lowerLimit.toStringAsFixed(1)}',
                          activeColor: const Color(0xFF66BB6A),
                          onChanged: (value) {
                            setState(() => _lowerLimit = value);
                          },
                          onChangeEnd: (_) => _saveLimits(),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<double?>(
            stream: _service.r0Mq135Stream(),
            builder: (context, mq135Snap) {
              final mq135 = (mq135Snap.data ?? _r0Mq135).toDouble();
              if ((mq135 - _r0Mq135).abs() > 0.0001) {
                _r0Mq135 = mq135;
              }
              return StreamBuilder<double?>(
                stream: _service.r0Mq2Stream(),
                builder: (context, mq2Snap) {
                  final mq2 = (mq2Snap.data ?? _r0Mq2).toDouble();
                  if ((mq2 - _r0Mq2).abs() > 0.0001) {
                    _r0Mq2 = mq2;
                  }
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0x332E7D32),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x55FFFFFF)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Kalibrasi Manual Sensor',
                          style: TextStyle(
                            color: Color(0xFFE8F5E9),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Set Cal Amonia: ${mq135.toStringAsFixed(4)}',
                                style: const TextStyle(
                                  color: Color(0xFFD7EFD9),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            _InlineInputButton(
                              onPressed: () async {
                                final value = await _showNumberInputDialog(
                                  context,
                                  title: 'Set Cal Amonia (R0 MQ135)',
                                  value: _r0Mq135,
                                  min: 0.0001,
                                  max: 100000,
                                  decimals: 4,
                                );
                                if (value == null) return;
                                setState(() => _r0Mq135 = value);
                                await _saveCalibrationR0(isMq135: true, value: value);
                              },
                              label: 'Input',
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Set Cal Metana: ${mq2.toStringAsFixed(4)}',
                                style: const TextStyle(
                                  color: Color(0xFFD7EFD9),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            _InlineInputButton(
                              onPressed: () async {
                                final value = await _showNumberInputDialog(
                                  context,
                                  title: 'Set Cal Metana (R0 MQ2)',
                                  value: _r0Mq2,
                                  min: 0.0001,
                                  max: 100000,
                                  decimals: 4,
                                );
                                if (value == null) return;
                                setState(() => _r0Mq2 = value);
                                await _saveCalibrationR0(isMq135: false, value: value);
                              },
                              label: 'Input',
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await _service.startCalibration();
                    await ActivityLoggerService.log(
                      action: 'monitoring.atc.calibration.start',
                      module: 'monitoring',
                      deviceId: widget.point.deviceId,
                      description: 'Memulai kalibrasi sensor ATC ${widget.point.name}',
                    );
                  },
                  icon: const Icon(Icons.science_outlined, size: 16),
                  label: const Text('Start Kalibrasi'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AtcSmartHydroponicControlCard extends StatefulWidget {
  final _MonitoringPoint point;

  const _AtcSmartHydroponicControlCard({required this.point});

  @override
  State<_AtcSmartHydroponicControlCard> createState() =>
      _AtcSmartHydroponicControlCardState();
}

class _AtcSmartHydroponicControlCardState
    extends State<_AtcSmartHydroponicControlCard> {
  late final AtcSmartHydroponicMqttService _service;
  double _phMin = 5.5;
  double _phMax = 7.0;
  double _tdsMin = 700;
  double _tdsMax = 1200;

  @override
  void initState() {
    super.initState();
    _service = AtcSmartHydroponicMqttService(
      deviceId: widget.point.deviceId,
      area: 'monitoring',
    );
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _saveLimits() async {
    final phMin = _phMin.clamp(0, 14).toDouble();
    final phMax = _phMax.clamp(phMin + 0.1, 14).toDouble();
    final tdsMin = _tdsMin.clamp(0, 4000).toDouble();
    final tdsMax = _tdsMax.clamp(tdsMin + 10, 5000).toDouble();
    setState(() {
      _phMin = phMin;
      _phMax = phMax;
      _tdsMin = tdsMin;
      _tdsMax = tdsMax;
    });
    await _service.setLimits(
      phMin: phMin,
      phMax: phMax,
      tdsMin: tdsMin,
      tdsMax: tdsMax,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.point.name,
                      style: const TextStyle(
                        color: Color(0xFFF1F8E9),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Smart Hidroponik',
                      style: const TextStyle(
                        color: Color(0xFFD7EFD9),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              StreamBuilder<bool>(
                stream: _service.onlineStream(),
                builder: (context, snap) => _StatusPill(online: snap.data ?? false),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Color(0xFFE8F5E9)),
                onSelected: (value) async {
                  if (value == 'refresh') {
                    await _service.requestStatus();
                  } else if (value == 'manual_off') {
                    await _service.setMode(false);
                    await _service.setRelayNutrient(false);
                    await _service.setRelayPhDown(false);
                  } else if (value == 'auto') {
                    await _service.setMode(true);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'refresh', child: Text('Refresh Status')),
                  PopupMenuItem(value: 'manual_off', child: Text('Manual + Semua Relay OFF')),
                  PopupMenuItem(value: 'auto', child: Text('Paksa Mode AUTO')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 420;
              final phTile = _MetricTile(
                label: 'pH',
                unit: '',
                icon: Icons.science,
                stream: _service.phStream(),
              );
              final tdsTile = _MetricTile(
                label: 'TDS',
                unit: 'ppm',
                icon: Icons.opacity,
                stream: _service.tdsStream(),
              );
              if (isNarrow) {
                return Column(children: [phTile, const SizedBox(height: 8), tdsTile]);
              }
              return Row(
                children: [
                  Expanded(child: phTile),
                  const SizedBox(width: 8),
                  Expanded(child: tdsTile),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<String>(
            stream: _service.systemMessageStream(),
            builder: (context, snap) {
              final text = (snap.data ?? 'System message: -').trim();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x332E7D32),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x55FFFFFF)),
                ),
                child: Text(
                  text,
                  style: const TextStyle(color: Color(0xFFE8F5E9), fontSize: 11),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<String>(
            stream: _service.modeStream(),
            builder: (context, modeSnap) {
              final autoMode = (modeSnap.data ?? 'manual').toLowerCase() == 'auto';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x332E7D32),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x55FFFFFF)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Mode Otomatis pH/TDS',
                            style: TextStyle(
                              color: Color(0xFFE8F5E9),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: autoMode,
                          activeColor: const Color(0xFF66BB6A),
                          onChanged: (value) => _service.setMode(value),
                        ),
                      ],
                    ),
                    if (!autoMode)
                      StreamBuilder<bool>(
                        stream: _service.relayNutrientStream(),
                        builder: (context, nutrientSnap) {
                          final nutrient = nutrientSnap.data ?? false;
                          return StreamBuilder<bool>(
                            stream: _service.relayPhDownStream(),
                            builder: (context, phDownSnap) {
                              final phDown = phDownSnap.data ?? false;
                              return Column(
                                children: [
                                  Row(
                                    children: [
                                      const Expanded(
                                        child: Text(
                                          'Relay Nutrisi',
                                          style: TextStyle(
                                            color: Color(0xFFE8F5E9),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      Switch.adaptive(
                                        value: nutrient,
                                        activeColor: const Color(0xFF66BB6A),
                                        onChanged: (value) => _service.setRelayNutrient(value),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      const Expanded(
                                        child: Text(
                                          'Relay pH Down',
                                          style: TextStyle(
                                            color: Color(0xFFE8F5E9),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      Switch.adaptive(
                                        value: phDown,
                                        activeColor: const Color(0xFF66BB6A),
                                        onChanged: (value) => _service.setRelayPhDown(value),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<double?>(
            stream: _service.phMinStream(),
            builder: (context, minSnap) {
              final phMin = (minSnap.data ?? _phMin).clamp(0, 14).toDouble();
              if ((phMin - _phMin).abs() > 0.001) _phMin = phMin;
              return StreamBuilder<double?>(
                stream: _service.phMaxStream(),
                builder: (context, maxSnap) {
                  final phMax = (maxSnap.data ?? _phMax).clamp(phMin + 0.1, 14).toDouble();
                  if ((phMax - _phMax).abs() > 0.001) _phMax = phMax;
                  return StreamBuilder<double?>(
                    stream: _service.tdsMinStream(),
                    builder: (context, tdsMinSnap) {
                      final tdsMin = (tdsMinSnap.data ?? _tdsMin).clamp(0, 4000).toDouble();
                      if ((tdsMin - _tdsMin).abs() > 0.001) _tdsMin = tdsMin;
                      return StreamBuilder<double?>(
                        stream: _service.tdsMaxStream(),
                        builder: (context, tdsMaxSnap) {
                          final tdsMax = (tdsMaxSnap.data ?? _tdsMax)
                              .clamp(tdsMin + 10, 5000)
                              .toDouble();
                          if ((tdsMax - _tdsMax).abs() > 0.001) _tdsMax = tdsMax;
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0x332E7D32),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0x55FFFFFF)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Batas pH/TDS',
                                  style: const TextStyle(
                                    color: Color(0xFFE8F5E9),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Slider(
                                  value: _phMin,
                                  min: 0,
                                  max: 14,
                                  divisions: 140,
                                  label: 'pH Min ${_phMin.toStringAsFixed(1)}',
                                  activeColor: const Color(0xFF81C784),
                                  onChanged: (value) {
                                    setState(() {
                                      _phMin = value;
                                      if (_phMax <= _phMin) _phMax = _phMin + 0.1;
                                    });
                                  },
                                  onChangeEnd: (_) => _saveLimits(),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () async {
                                      final value = await _showNumberInputDialog(
                                        context,
                                        title: 'pH Min',
                                        value: _phMin,
                                        min: 0,
                                        max: 14,
                                        decimals: 1,
                                      );
                                      if (value == null) return;
                                      setState(() {
                                        _phMin = value;
                                        if (_phMax <= _phMin) _phMax = _phMin + 0.1;
                                      });
                                      await _saveLimits();
                                    },
                                    child: const Text('Input pH Min'),
                                  ),
                                ),
                                Slider(
                                  value: _phMax,
                                  min: (_phMin + 0.1).clamp(0.1, 14).toDouble(),
                                  max: 14,
                                  divisions: 139,
                                  label: 'pH Max ${_phMax.toStringAsFixed(1)}',
                                  activeColor: const Color(0xFF66BB6A),
                                  onChanged: (value) {
                                    setState(() => _phMax = value);
                                  },
                                  onChangeEnd: (_) => _saveLimits(),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () async {
                                      final minValue = (_phMin + 0.1).clamp(0.1, 14).toDouble();
                                      final value = await _showNumberInputDialog(
                                        context,
                                        title: 'pH Max',
                                        value: _phMax,
                                        min: minValue,
                                        max: 14,
                                        decimals: 1,
                                      );
                                      if (value == null) return;
                                      setState(() => _phMax = value.clamp(minValue, 14));
                                      await _saveLimits();
                                    },
                                    child: const Text('Input pH Max'),
                                  ),
                                ),
                                Slider(
                                  value: _tdsMin,
                                  min: 0,
                                  max: 4000,
                                  divisions: 400,
                                  label: 'TDS Min ${_tdsMin.toStringAsFixed(0)}',
                                  activeColor: const Color(0xFF81C784),
                                  onChanged: (value) {
                                    setState(() {
                                      _tdsMin = value;
                                      if (_tdsMax <= _tdsMin) _tdsMax = _tdsMin + 10;
                                    });
                                  },
                                  onChangeEnd: (_) => _saveLimits(),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () async {
                                      final value = await _showNumberInputDialog(
                                        context,
                                        title: 'TDS Min',
                                        value: _tdsMin,
                                        min: 0,
                                        max: 4000,
                                        decimals: 0,
                                      );
                                      if (value == null) return;
                                      setState(() {
                                        _tdsMin = value;
                                        if (_tdsMax <= _tdsMin) _tdsMax = _tdsMin + 10;
                                      });
                                      await _saveLimits();
                                    },
                                    child: const Text('Input TDS Min'),
                                  ),
                                ),
                                Slider(
                                  value: _tdsMax,
                                  min: (_tdsMin + 10).clamp(10, 5000).toDouble(),
                                  max: 5000,
                                  divisions: 499,
                                  label: 'TDS Max ${_tdsMax.toStringAsFixed(0)}',
                                  activeColor: const Color(0xFF66BB6A),
                                  onChanged: (value) {
                                    setState(() => _tdsMax = value);
                                  },
                                  onChangeEnd: (_) => _saveLimits(),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () async {
                                      final minValue = (_tdsMin + 10).clamp(10, 5000).toDouble();
                                      final value = await _showNumberInputDialog(
                                        context,
                                        title: 'TDS Max',
                                        value: _tdsMax,
                                        min: minValue,
                                        max: 5000,
                                        decimals: 0,
                                      );
                                      if (value == null) return;
                                      setState(() => _tdsMax = value.clamp(minValue, 5000));
                                      await _saveLimits();
                                    },
                                    child: const Text('Input TDS Max'),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AtcIrrigationControlCard extends StatefulWidget {
  final _MonitoringPoint point;

  const _AtcIrrigationControlCard({required this.point});

  @override
  State<_AtcIrrigationControlCard> createState() => _AtcIrrigationControlCardState();
}

class _AtcIrrigationControlCardState extends State<_AtcIrrigationControlCard> {
  late final AtcIrrigationMqttService _service;
  double _pumpDurationSec = 30;
  double _sprayerDurationSec = 20;
  List<TimeOfDay> _pumpTimes = const [];
  List<TimeOfDay> _sprayerTimes = const [];
  bool _pumpScheduleDirty = false;
  bool _sprayerScheduleDirty = false;
  String _selectedChartMetric = 'temperature';

  @override
  void initState() {
    super.initState();
    _service = AtcIrrigationMqttService(deviceId: widget.point.deviceId, area: 'monitoring');
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  List<TimeOfDay> _decodeTimes(List<String> raw) {
    return raw
        .map((value) {
          final parts = value.split(':');
          if (parts.length != 2) return null;
          final hour = int.tryParse(parts[0]);
          final minute = int.tryParse(parts[1]);
          if (hour == null || minute == null) return null;
          if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
          return TimeOfDay(hour: hour, minute: minute);
        })
        .whereType<TimeOfDay>()
        .toList();
  }

  String _formatTime(TimeOfDay time) {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Future<void> _savePumpSchedule() async {
    final duration = _pumpDurationSec.clamp(5, 300).round();
    await _service.setPumpSchedule(
      times: _pumpTimes.map(_formatTime).toList(),
      durationSec: duration,
    );
    if (mounted) {
      setState(() => _pumpScheduleDirty = false);
    }
    await ActivityLoggerService.log(
      action: 'monitoring.atc.irrigation.pump_schedule.save',
      module: 'monitoring',
      deviceId: widget.point.deviceId,
      description:
          'Menyimpan jadwal pompa ${widget.point.name}: ${_pumpTimes.map(_formatTime).join(", ")} (${duration}s)',
    );
  }

  Future<void> _saveSprayerSchedule() async {
    final duration = _sprayerDurationSec.clamp(5, 300).round();
    await _service.setSprayerSchedule(
      times: _sprayerTimes.map(_formatTime).toList(),
      durationSec: duration,
    );
    if (mounted) {
      setState(() => _sprayerScheduleDirty = false);
    }
    await ActivityLoggerService.log(
      action: 'monitoring.atc.irrigation.sprayer_schedule.save',
      module: 'monitoring',
      deviceId: widget.point.deviceId,
      description:
          'Menyimpan jadwal sprayer ${widget.point.name}: ${_sprayerTimes.map(_formatTime).join(", ")} (${duration}s)',
    );
  }

  Widget _buildTimerStatusChip({
    required String label,
    required Stream<int?> stream,
  }) {
    return StreamBuilder<int?>(
      stream: stream,
      builder: (context, snapshot) {
        final remaining = snapshot.data;
        final active = remaining != null && remaining > 0;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? const Color(0x2648C774) : const Color(0x18FFFFFF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active ? const Color(0xFF7BE495) : const Color(0x44FFFFFF),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? Icons.hourglass_bottom_rounded : Icons.timer_off_outlined,
                size: 15,
                color: active ? const Color(0xFFB9F6CA) : const Color(0xFFD7EFD9),
              ),
              const SizedBox(width: 6),
              Text(
                active ? '$label: $remaining dtk' : '$label: standby',
                style: TextStyle(
                  color: active ? const Color(0xFFF1FFF4) : const Color(0xFFD7EFD9),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickTime({
    required bool forPump,
    required List<TimeOfDay> current,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: forPump ? 'Tambah Jadwal Pompa' : 'Tambah Jadwal Sprayer',
    );
    if (picked == null) return;
    await ActivityLoggerService.log(
      action: forPump
          ? 'monitoring.atc.irrigation.pump_schedule.add_time'
          : 'monitoring.atc.irrigation.sprayer_schedule.add_time',
      module: 'monitoring',
      deviceId: widget.point.deviceId,
      description:
          'Menambahkan jam ${forPump ? "pompa" : "sprayer"} ${_formatTime(picked)} pada ${widget.point.name}',
      metadata: {
        'role': forPump ? 'pump' : 'sprayer',
        'time': _formatTime(picked),
      },
    );
    final next = List<TimeOfDay>.from(current)..add(picked);
    next.sort((a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));
    setState(() {
      if (forPump) {
        _pumpTimes = next;
        _pumpScheduleDirty = true;
      } else {
        _sprayerTimes = next;
        _sprayerScheduleDirty = true;
      }
    });
  }

  Widget _buildScheduleSection({
    required String title,
    required IconData icon,
    required List<TimeOfDay> times,
    required double duration,
    required ValueChanged<double> onDurationChanged,
    required VoidCallback onSave,
    required VoidCallback onAddTime,
    required void Function(int index) onRemoveTime,
    required Stream<int?> remainingStream,
    required bool isDirty,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFFB9E5BE), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFE8F5E9),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _buildTimerStatusChip(label: 'Aktif', stream: remainingStream),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < times.length; i++)
                Chip(
                  backgroundColor: const Color(0x2648C774),
                  avatar: const Icon(Icons.schedule, size: 16, color: Color(0xFFE8F5E9)),
                  label: Text(
                    _formatTime(times[i]),
                    style: const TextStyle(color: Color(0xFFE8F5E9)),
                  ),
                  deleteIconColor: const Color(0xFFE8F5E9),
                  onDeleted: () => onRemoveTime(i),
                ),
              ActionChip(
                backgroundColor: const Color(0xFF2E7D32),
                avatar: const Icon(Icons.add, size: 18, color: Color(0xFFE8F5E9)),
                label: const Text(
                  'Tambah Jam',
                  style: TextStyle(color: Color(0xFFE8F5E9)),
                ),
                onPressed: onAddTime,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Durasi aktif: ${duration.round()} detik',
            style: const TextStyle(
              color: Color(0xFFD7EFD9),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          Slider(
            value: duration,
            min: 5,
            max: 300,
            divisions: 59,
            label: '${duration.round()} detik',
            activeColor: const Color(0xFF81C784),
            onChanged: onDurationChanged,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _InlineInputButton(
              onPressed: () async {
                final value = await _showNumberInputDialog(
                  context,
                  title: '$title (detik)',
                  value: duration,
                  min: 5,
                  max: 300,
                  decimals: 0,
                );
                if (value == null) return;
                onDurationChanged(value);
              },
              label: 'Input Durasi',
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: isDirty ? const Color(0xFFD84343) : const Color(0xFF2E7D32),
                foregroundColor: const Color(0xFFF7FFF8),
              ),
              onPressed: onSave,
              icon: Icon(
                isDirty ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
                size: 18,
              ),
              label: Text(isDirty ? 'Simpan Jadwal Baru' : 'Jadwal Tersimpan'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildManualRelayToggleSection() {
    Future<void> handleToggle({
      required String relay,
      required bool enabled,
      required int durationSec,
      required String relayLabel,
    }) async {
      await _service.setRelayState(
        relay: relay,
        enabled: enabled,
        durationSec: durationSec,
      );
      await ActivityLoggerService.log(
        action: 'monitoring.atc.irrigation.relay.manual_toggle',
        module: 'monitoring',
        deviceId: widget.point.deviceId,
        description:
            'Toggle manual $relayLabel ${widget.point.name}: ${enabled ? "ON" : "OFF"} (${durationSec}s)',
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.toggle_on_rounded, color: Color(0xFFB9E5BE), size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Test Relay Manual',
                  style: TextStyle(
                    color: Color(0xFFE8F5E9),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Toggle tetap normal. Saat ON di app, firmware akan men-trigger relay aktif-low secara fisik. Relay bisa dimatikan manual kapan saja.',
            style: TextStyle(
              color: Color(0xFFD7EFD9),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StreamBuilder<bool>(
                  stream: _service.relayPumpStream(),
                  builder: (context, snapshot) {
                    final isOn = snapshot.data ?? false;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0x1FFFFFFF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Pompa',
                                  style: TextStyle(
                                    color: Color(0xFFE8F5E9),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Toggle manual untuk uji relay pompa',
                                  style: TextStyle(
                                    color: Color(0xFFD7EFD9),
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: isOn,
                            onChanged: (value) => handleToggle(
                              relay: 'relay_pump',
                              enabled: value,
                              durationSec: _pumpDurationSec.round(),
                              relayLabel: 'pompa',
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StreamBuilder<bool>(
                  stream: _service.relaySprayerStream(),
                  builder: (context, snapshot) {
                    final isOn = snapshot.data ?? false;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0x1FFFFFFF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sprayer',
                                  style: TextStyle(
                                    color: Color(0xFFE8F5E9),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Toggle manual untuk uji relay sprayer',
                                  style: TextStyle(
                                    color: Color(0xFFD7EFD9),
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: isOn,
                            onChanged: (value) => handleToggle(
                              relay: 'relay_sprayer',
                              enabled: value,
                              durationSec: _sprayerDurationSec.round(),
                              relayLabel: 'sprayer',
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRealtimeChartSection() {
    final options = <String, ({String label, String unit, Color color})>{
      'temperature': (label: 'Suhu', unit: 'C', color: const Color(0xFFFFB74D)),
      'humidity': (label: 'Kelembapan', unit: '%', color: const Color(0xFF4FC3F7)),
      'soil_moisture': (label: 'Kelembapan Tanah', unit: '%', color: const Color(0xFF81C784)),
    };
    final selected = options[_selectedChartMetric] ?? options['temperature']!;

    return StreamBuilder<double?>(
      stream: _service.temperatureStream(),
      builder: (context, _) {
        return StreamBuilder<double?>(
          stream: _service.humidityStream(),
          builder: (context, __) {
            return StreamBuilder<double?>(
              stream: _service.soilMoistureStream(),
              builder: (context, ___) {
                final history = _service.historyFor(_selectedChartMetric);
                final spots = <FlSpot>[];
                for (var i = 0; i < history.length; i++) {
                  spots.add(FlSpot(i.toDouble(), history[i].value));
                }
                return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Chart Realtime Monitoring',
            style: TextStyle(
              color: Color(0xFFE8F5E9),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: options.entries.map((entry) {
              final active = _selectedChartMetric == entry.key;
              return ChoiceChip(
                label: Text(entry.value.label),
                selected: active,
                selectedColor: const Color(0xFF2E7D32),
                backgroundColor: const Color(0x221A4A28),
                side: const BorderSide(color: Color(0x44FFFFFF)),
                labelStyle: TextStyle(
                  color: active ? const Color(0xFFF1F8E9) : const Color(0xFFD7EFD9),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                onSelected: (_) => setState(() => _selectedChartMetric = entry.key),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          _MiniRealtimeChart(
            title: selected.label,
            unit: selected.unit,
            color: selected.color,
            spots: spots,
            emptyMessage: 'Menunggu telemetry realtime...',
          ),
        ],
      ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.point.name,
                      style: const TextStyle(
                        color: Color(0xFFF1F8E9),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Irigasi (${widget.point.deviceId})',
                      style: const TextStyle(
                        color: Color(0xFFD7EFD9),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              StreamBuilder<bool>(
                stream: _service.onlineStream(),
                builder: (context, snap) => _StatusPill(online: snap.data ?? false),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Color(0xFFE8F5E9)),
                onSelected: (value) async {
                  if (value == 'refresh') {
                    await _service.requestStatus();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'refresh', child: Text('Refresh Status')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 420;
              final tempTile = _MetricTile(
                label: 'Suhu',
                unit: 'C',
                icon: Icons.thermostat,
                stream: _service.temperatureStream(),
              );
              final humidityTile = _MetricTile(
                label: 'Kelembapan',
                unit: '%',
                icon: Icons.water_drop,
                stream: _service.humidityStream(),
              );
              final soilTile = _MetricTile(
                label: 'Kelembapan Tanah',
                unit: '%',
                icon: Icons.grass,
                stream: _service.soilMoistureStream(),
              );

              if (isNarrow) {
                return Column(
                  children: [
                    tempTile,
                    const SizedBox(height: 8),
                    humidityTile,
                    const SizedBox(height: 8),
                    soilTile,
                  ],
                );
              }

              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: tempTile),
                      const SizedBox(width: 8),
                      Expanded(child: humidityTile),
                    ],
                  ),
                  const SizedBox(height: 8),
                  soilTile,
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          _buildRealtimeChartSection(),
          const SizedBox(height: 8),
          StreamBuilder<String>(
            stream: _service.systemMessageStream(),
            builder: (context, snap) {
              final text = (snap.data ?? 'System message: -').trim();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x332E7D32),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x55FFFFFF)),
                ),
                child: Text(
                  text,
                  style: const TextStyle(color: Color(0xFFE8F5E9), fontSize: 11),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x332E7D32),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x55FFFFFF)),
            ),
            child: const Text(
              'Sensor hanya dipakai untuk monitoring. Kontrol relay pompa dan sprayer dijalankan lewat penjadwalan harian beserta durasi aktifnya.',
              style: TextStyle(color: Color(0xFFE8F5E9), fontSize: 11),
            ),
          ),
          const SizedBox(height: 8),
          _buildManualRelayToggleSection(),
          const SizedBox(height: 8),
          StreamBuilder<List<String>>(
            stream: _service.pumpScheduleStream(),
            builder: (context, timesSnap) {
              if (timesSnap.hasData && !_pumpScheduleDirty) {
                _pumpTimes = _decodeTimes(timesSnap.data!);
              }
              return StreamBuilder<int?>(
                stream: _service.pumpDurationStream(),
                builder: (context, durationSnap) {
                  final duration = (durationSnap.data ?? _pumpDurationSec).clamp(5, 300).toDouble();
                  if ((duration - _pumpDurationSec).abs() > 0.001 && !_pumpScheduleDirty) {
                    _pumpDurationSec = duration;
                  }
                  return _buildScheduleSection(
                    title: 'Jadwal Relay Pompa',
                    icon: Icons.water,
                    times: _pumpTimes,
                    duration: _pumpDurationSec,
                    onDurationChanged: (value) => setState(() {
                      _pumpDurationSec = value;
                      _pumpScheduleDirty = true;
                    }),
                    onSave: _savePumpSchedule,
                    onAddTime: () => _pickTime(forPump: true, current: _pumpTimes),
                    onRemoveTime: (index) async {
                      final removed = _formatTime(_pumpTimes[index]);
                      await ActivityLoggerService.log(
                        action: 'monitoring.atc.irrigation.pump_schedule.remove_time',
                        module: 'monitoring',
                        deviceId: widget.point.deviceId,
                        description:
                            'Menghapus jam pompa $removed pada ${widget.point.name}',
                        metadata: {'role': 'pump', 'time': removed},
                      );
                      setState(() {
                        _pumpTimes = List.of(_pumpTimes)..removeAt(index);
                        _pumpScheduleDirty = true;
                      });
                    },
                    remainingStream: _service.pumpRemainingStream(),
                    isDirty: _pumpScheduleDirty,
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<List<String>>(
            stream: _service.sprayerScheduleStream(),
            builder: (context, timesSnap) {
              if (timesSnap.hasData && !_sprayerScheduleDirty) {
                _sprayerTimes = _decodeTimes(timesSnap.data!);
              }
              return StreamBuilder<int?>(
                stream: _service.sprayerDurationStream(),
                builder: (context, durationSnap) {
                  final duration =
                      (durationSnap.data ?? _sprayerDurationSec).clamp(5, 300).toDouble();
                  if ((duration - _sprayerDurationSec).abs() > 0.001 && !_sprayerScheduleDirty) {
                    _sprayerDurationSec = duration;
                  }
                  return _buildScheduleSection(
                    title: 'Jadwal Relay Sprayer',
                    icon: Icons.grass,
                    times: _sprayerTimes,
                    duration: _sprayerDurationSec,
                    onDurationChanged: (value) => setState(() {
                      _sprayerDurationSec = value;
                      _sprayerScheduleDirty = true;
                    }),
                    onSave: _saveSprayerSchedule,
                    onAddTime: () => _pickTime(forPump: false, current: _sprayerTimes),
                    onRemoveTime: (index) async {
                      final removed = _formatTime(_sprayerTimes[index]);
                      await ActivityLoggerService.log(
                        action: 'monitoring.atc.irrigation.sprayer_schedule.remove_time',
                        module: 'monitoring',
                        deviceId: widget.point.deviceId,
                        description:
                            'Menghapus jam sprayer $removed pada ${widget.point.name}',
                        metadata: {'role': 'sprayer', 'time': removed},
                      );
                      setState(() {
                        _sprayerTimes = List.of(_sprayerTimes)..removeAt(index);
                        _sprayerScheduleDirty = true;
                      });
                    },
                    remainingStream: _service.sprayerRemainingStream(),
                    isDirty: _sprayerScheduleDirty,
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

Future<double?> _showNumberInputDialog(
  BuildContext context, {
  required String title,
  required double value,
  required double min,
  required double max,
  int decimals = 0,
}) async {
  final controller = TextEditingController(
    text: value.toStringAsFixed(decimals),
  );
  final result = await showDialog<double>(
    context: context,
    builder: (context) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              colors: [
                Color(0xFF184B2B),
                Color(0xFF1F5F35),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: const Color(0x66D7EFD9)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.28),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0x3348C774),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.edit_note_rounded,
                      color: Color(0xFFE8F5E9),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Color(0xFFF4FFF6),
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Masukkan angka antara ${min.toStringAsFixed(decimals)} sampai ${max.toStringAsFixed(decimals)}.',
                          style: const TextStyle(
                            color: Color(0xFFD7EFD9),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0x1AFFFFFF),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0x55FFFFFF)),
                ),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.numberWithOptions(decimal: decimals > 0),
                  style: const TextStyle(
                    color: Color(0xFFF4FFF6),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    hintText: '$min - $max',
                    hintStyle: const TextStyle(color: Color(0x99D7EFD9)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    suffixIcon: const Padding(
                      padding: EdgeInsets.only(right: 14),
                      child: Icon(Icons.pin_outlined, color: Color(0xFFB9E5BE), size: 20),
                    ),
                    suffixIconConstraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _QuickValueChip(
                    label: 'Min',
                    onTap: () => controller.text = min.toStringAsFixed(decimals),
                  ),
                  _QuickValueChip(
                    label: 'Tengah',
                    onTap: () => controller.text = ((min + max) / 2).toStringAsFixed(decimals),
                  ),
                  _QuickValueChip(
                    label: 'Max',
                    onTap: () => controller.text = max.toStringAsFixed(decimals),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFE8F5E9),
                        side: const BorderSide(color: Color(0x66D7EFD9)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('Batal'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        final raw = controller.text.trim().replaceAll(',', '.');
                        final parsed = double.tryParse(raw);
                        if (parsed == null) {
                          Navigator.pop(context);
                          return;
                        }
                        final clamped = parsed.clamp(min, max).toDouble();
                        Navigator.pop(context, clamped);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF66BB6A),
                        foregroundColor: const Color(0xFF10341D),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Simpan',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return result;
}

class _QuickValueChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickValueChip({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x2248C774),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x55D7EFD9)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFFF4FFF6),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _InlineInputButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _InlineInputButton({
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF2D6A3A),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFF93D7A3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.edit_rounded,
                size: 14,
                color: Color(0xFFF4FFF6),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFF4FFF6),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniRealtimeChart extends StatelessWidget {
  final String title;
  final String unit;
  final Color color;
  final List<FlSpot> spots;
  final String emptyMessage;

  const _MiniRealtimeChart({
    required this.title,
    required this.unit,
    required this.color,
    required this.spots,
    required this.emptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0x1AFFFFFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: spots.isEmpty
          ? Center(
              child: Text(
                emptyMessage,
                style: const TextStyle(
                  color: Color(0xFFD7EFD9),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title (${spots.last.y.toStringAsFixed(1)} $unit)',
                  style: const TextStyle(
                    color: Color(0xFFE8F5E9),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: spots.length <= 1 ? 1 : (spots.length - 1).toDouble(),
                      minY: _minY(spots),
                      maxY: _maxY(spots),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: _intervalY(spots),
                        getDrawingHorizontalLine: (_) => const FlLine(
                          color: Color(0x223D6847),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 34,
                            interval: _intervalY(spots),
                            getTitlesWidget: (value, _) => Text(
                              value.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Color(0xFFC8E6C9),
                                fontSize: 9,
                              ),
                            ),
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
                          isCurved: true,
                          color: color,
                          barWidth: 2.6,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              colors: [
                                color.withOpacity(0.28),
                                color.withOpacity(0.03),
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

  static double _minY(List<FlSpot> spots) {
    final min = spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final max = spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    if (min == max) return min - 1;
    return min - (max - min) * 0.15;
  }

  static double _maxY(List<FlSpot> spots) {
    final min = spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final max = spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    if (min == max) return max + 1;
    return max + (max - min) * 0.15;
  }

  static double _intervalY(List<FlSpot> spots) {
    final min = spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final max = spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    final diff = (max - min).abs();
    if (diff <= 1) return 0.5;
    if (diff <= 5) return 1;
    if (diff <= 20) return 5;
    if (diff <= 100) return 10;
    return diff / 4;
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String unit;
  final IconData icon;
  final Stream<double?> stream;

  const _MetricTile({
    required this.label,
    required this.unit,
    required this.icon,
    required this.stream,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double?>(
      stream: stream,
      builder: (context, snapshot) {
        final value = snapshot.data;
        final display = value == null ? '-' : value.toStringAsFixed(1);

        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: const Color(0x332E7D32),
            border: Border.all(color: const Color(0x55FFFFFF)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.16),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0x334CAF50),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: const Color(0xFFB9E5BE), size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFFD7EFD9),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$display $unit',
                      style: const TextStyle(
                        color: Color(0xFFF1F8E9),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool online;

  const _StatusPill({required this.online});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 74),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: online ? const Color(0x2E81C784) : const Color(0x33EF5350),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: online ? const Color(0x6681C784) : const Color(0x66EF5350),
        ),
        boxShadow: [
          BoxShadow(
            color: (online ? const Color(0x3381C784) : const Color(0x33EF5350))
                .withOpacity(0.45),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? const Color(0xFF81C784) : const Color(0xFFEF5350),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            online ? 'Online' : 'Offline',
            style: TextStyle(
              color: online ? const Color(0xFFE8F5E9) : const Color(0xFFFFCDD2),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroInfoCard extends StatelessWidget {
  const _HeroInfoCard();

  @override
  Widget build(BuildContext context) {
    return const _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pilih Area',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontSize: 21,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'BC-1: Buncob 1  |  BC-2: Buncob 2  |  ATC: Agro Tech Center',
            style: TextStyle(color: Color(0xFFD7EFD9), fontSize: 12),
          ),
          SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _ChipLabel(label: 'Monitoring Area'),
              _ChipLabel(label: 'Multi Titik'),
              _ChipLabel(label: 'Realtime'),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;

  const _GlassCard({
    required this.child,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xB0143725),
        border: Border.all(color: const Color(0x66FFFFFF)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: const Color(0x334CAF50).withOpacity(0.30),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ChipLabel extends StatelessWidget {
  final String label;

  const _ChipLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x66FFFFFF)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.14),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFE8F5E9),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PageBackground extends StatelessWidget {
  const _PageBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0E2A1A), Color(0xFF2E7D32), Color(0xFF66BB6A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -100,
            right: -80,
            child: _orb(const Color(0x8058B66A), 220),
          ),
          Positioned(
            bottom: -120,
            left: -90,
            child: _orb(const Color(0x8066BB6A), 260),
          ),
          Positioned(
            top: 180,
            left: -20,
            child: _orb(const Color(0x558BC34A), 140),
          ),
        ],
      ),
    );
  }

  Widget _orb(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }
}

class _AreaConfig {
  final String code;
  final String title;
  final String subtitle;
  final String? imageAsset;
  final List<_MonitoringPoint> points;

  const _AreaConfig({
    required this.code,
    required this.title,
    required this.subtitle,
    required this.imageAsset,
    required this.points,
  });
}

class _MonitoringPoint {
  final String name;
  final String deviceId;
  final _MonitoringPointKind kind;

  const _MonitoringPoint({
    required this.name,
    required this.deviceId,
    this.kind = _MonitoringPointKind.standard,
  });
}

enum _MonitoringPointKind {
  standard,
  atcEnviro,
  atcSmartHydroponic,
  atcIrrigation,
}
