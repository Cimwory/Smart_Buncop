import 'package:flutter/material.dart';

import '../services/nutrimix_mqtt_service.dart';
import '../services/activity_logger_service.dart';
import 'device_selector_page.dart';

class NutrimixPage extends StatefulWidget {
  final String deviceId;

  const NutrimixPage({
    super.key,
    required this.deviceId,
  });

  @override
  State<NutrimixPage> createState() => _NutrimixPageState();
}

class _NutrimixPageState extends State<NutrimixPage> {
  late final NutrimixMqttService _nutrimixService;
  late final Stream<bool> _espOnlineStream;
  final TextEditingController _targetController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nutrimixService = NutrimixMqttService(widget.deviceId);
    _espOnlineStream = _nutrimixService.espOnlineStream();
    ActivityLoggerService.log(
      action: 'screen.open',
      module: 'nutrimix',
      deviceId: widget.deviceId,
      description: 'Membuka halaman nutrimix (device: ${widget.deviceId})',
    );
  }

  @override
  void dispose() {
    _targetController.dispose();
    _nutrimixService.dispose();
    super.dispose();
  }

  Future<void> _submitStart() async {
    final target = int.tryParse(_targetController.text.trim());
    if (target == null || target <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Target berat harus angka > 0 gram')),
      );
      return;
    }

    await _nutrimixService.startBatch(targetWeight: target);
    await ActivityLoggerService.log(
      action: 'nutrimix.batch.start',
      module: 'nutrimix',
      deviceId: widget.deviceId,
      description: 'Memulai batch nutrimix dengan target ${target}g pada device ${widget.deviceId}',
      metadata: {'target_weight_g': target},
    );
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Proses Nutrimix dimulai (target $target g)')),
    );
  }

  Future<void> _emergencyStop() async {
    await _nutrimixService.emergencyStop();
    await ActivityLoggerService.log(
      action: 'nutrimix.batch.stop',
      module: 'nutrimix',
      deviceId: widget.deviceId,
      description: 'Emergency stop nutrimix pada device ${widget.deviceId}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Emergency stop dikirim ke ESP')),
    );
  }

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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Pilih Perangkat',
          onPressed: () {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const DeviceSelectorPage()),
              (route) => false,
            );
          },
        ),
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _headerCard(),
                    const SizedBox(height: 10),
                    _quickRibbon(),
                    const SizedBox(height: 12),
                    _sectionTitle('Control'),
                    const SizedBox(height: 8),
                    _responsivePair(
                      width: width,
                      first: _controlCard(),
                      second: _timingSetupCard(),
                    ),
                    const SizedBox(height: 12),
                    _sectionTitle('Realtime Monitoring'),
                    const SizedBox(height: 8),
                    _responsivePair(
                      width: width,
                      first: _weightMonitoringCard(),
                      second: _processStateCard(),
                    ),
                    const SizedBox(height: 12),
                    _sectionTitle('Actuator & Tolerance'),
                    const SizedBox(height: 8),
                    _responsivePair(
                      width: width,
                      first: _actuatorCard(),
                      second: _tuningCard(),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFFE8F5E9),
          fontSize: 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _quickRibbon() {
    return _panel(
      child: const Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _MiniTag(icon: Icons.memory, text: 'Nutrimix Line'),
          _MiniTag(icon: Icons.tune, text: 'Dynamic Config'),
          _MiniTag(icon: Icons.hub, text: 'ESP Realtime'),
        ],
      ),
    );
  }

  Widget _responsivePair({
    required double width,
    required Widget first,
    required Widget second,
  }) {
    if (width >= 920) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 10),
          Expanded(child: second),
        ],
      );
    }

    return Column(
      children: [
        first,
        const SizedBox(height: 10),
        second,
      ],
    );
  }

  Widget _headerCard() {
    return _panel(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Device Nutrimix',
                      style: TextStyle(
                        color: Color(0xFFD7EFD9),
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      widget.deviceId,
                      style: const TextStyle(
                        color: Color(0xFFF1F8E9),
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              StreamBuilder<bool>(
                stream: _espOnlineStream,
                builder: (context, snap) {
                  final online = snap.data ?? false;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: online ? const Color(0x2D81C784) : const Color(0x33EF5350),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: online ? const Color(0x6681C784) : const Color(0x66EF5350),
                      ),
                    ),
                    child: Text(
                      online ? 'ESP ONLINE' : 'ESP OFFLINE',
                      style: TextStyle(
                        color: online ? const Color(0xFFE8F5E9) : const Color(0xFFFFCDD2),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _espTag('Page: Nutrimix'),
              _espTag('ESP Controller + Monitoring'),
              _espTag('ESP: ${widget.deviceId}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlCard() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Kontrol Batch Pupuk',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          StreamBuilder<int>(
            stream: _nutrimixService.servoDurationStream(),
            builder: (context, servoSnap) {
              final servoDuration = servoSnap.data ?? 5;
              return StreamBuilder<int>(
                stream: _nutrimixService.trimmerDurationStream(),
                builder: (context, trimmerSnap) {
                  final trimmerDuration = trimmerSnap.data ?? 20;
                  return Text(
                    'Alur: Input target -> Screw dosing -> Servo $servoDuration detik -> Trimmer $trimmerDuration detik -> Selesai',
                    style: const TextStyle(
                      color: Color(0xFFD7EFD9),
                      fontSize: 12,
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Color(0xFFE8F5E9)),
            decoration: InputDecoration(
              labelText: 'Target Berat (gram)',
              hintText: 'contoh: 250',
              labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
              hintStyle: const TextStyle(color: Color(0x99C8E6C9)),
              filled: true,
              fillColor: Colors.white.withOpacity(0.06),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFF81C784)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [100, 250, 500, 1000].map((value) {
              return ActionChip(
                label: Text('$value g'),
                onPressed: () => setState(() => _targetController.text = '$value'),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 460;
              if (isNarrow) {
                return Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _submitStart,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Mulai Proses'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF66BB6A),
                          foregroundColor: const Color.fromARGB(255, 14, 14, 14),
                          minimumSize: const Size.fromHeight(46),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _emergencyStop,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Emergency Stop'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFFFCDD2),
                          side: const BorderSide(color: Color(0x66EF5350)),
                          minimumSize: const Size.fromHeight(46),
                        ),
                      ),
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _submitStart,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Mulai Proses'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF66BB6A),
                        foregroundColor: const Color.fromARGB(255, 14, 14, 14),
                        minimumSize: const Size.fromHeight(46),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _emergencyStop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Emergency Stop'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFFCDD2),
                        side: const BorderSide(color: Color(0x66EF5350)),
                        minimumSize: const Size.fromHeight(46),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _timingSetupCard() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pengaturan Aktuator',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Atur sudut servo (0-180), lama servo terbuka, dan lama trimmer.',
            style: TextStyle(color: Color(0xFFD7EFD9), fontSize: 12),
          ),
          const SizedBox(height: 10),
          _ConfigIntSlider(
            title: 'Sudut Servo Open',
            min: 0,
            max: 180,
            unit: 'deg',
            stream: _nutrimixService.servoOpenAngleStream(),
            onSubmit: (value) async {
              await _nutrimixService.setServoOpenAngle(value);
              await ActivityLoggerService.log(
                action: 'nutrimix.config.servo_angle',
                module: 'nutrimix',
                deviceId: widget.deviceId,
                description: 'Ubah sudut servo menjadi $value deg pada device ${widget.deviceId}',
                metadata: {'servo_open_angle_deg': value},
              );
            },
          ),
          const SizedBox(height: 8),
          _ConfigIntSlider(
            title: 'Durasi Servo Open',
            min: 1,
            max: 30,
            unit: 's',
            stream: _nutrimixService.servoDurationStream(),
            onSubmit: (value) async {
              await _nutrimixService.setServoOpenDuration(value);
              await ActivityLoggerService.log(
                action: 'nutrimix.config.servo_duration',
                module: 'nutrimix',
                deviceId: widget.deviceId,
                description: 'Ubah durasi servo menjadi ${value}s pada device ${widget.deviceId}',
                metadata: {'servo_open_duration_s': value},
              );
            },
          ),
          const SizedBox(height: 8),
          _ConfigIntSlider(
            title: 'Durasi Trimmer ON',
            min: 1,
            max: 120,
            unit: 's',
            stream: _nutrimixService.trimmerDurationStream(),
            onSubmit: (value) async {
              await _nutrimixService.setTrimmerDuration(value);
              await ActivityLoggerService.log(
                action: 'nutrimix.config.trimmer_duration',
                module: 'nutrimix',
                deviceId: widget.deviceId,
                description: 'Ubah durasi trimmer menjadi ${value}s pada device ${widget.deviceId}',
                metadata: {'trimmer_duration_s': value},
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _weightMonitoringCard() {
    return _panel(
      child: StreamBuilder<int?>(
        stream: _nutrimixService.targetWeightStream(),
        builder: (context, targetSnap) {
          final targetWeight = (targetSnap.data ?? 0).toDouble();
          return StreamBuilder<double>(
            stream: _nutrimixService.filteredWeightStream(),
            builder: (context, filteredSnap) {
              final filteredWeight = filteredSnap.data ?? 0;
              final progress = targetWeight > 0 ? (filteredWeight / targetWeight).clamp(0, 1) : 0;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Monitoring Timbangan (HX711)',
                    style: TextStyle(
                      color: Color(0xFFF1F8E9),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _metricBox(
                          title: 'Berat Aktual',
                          value: '${filteredWeight.toStringAsFixed(1)} g',
                          icon: Icons.scale_outlined,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _metricBox(
                          title: 'Target',
                          value: '${targetWeight.toStringAsFixed(0)} g',
                          icon: Icons.flag_outlined,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: progress.toDouble(),
                    minHeight: 8,
                    backgroundColor: Colors.white.withOpacity(0.15),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF81C784)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Progres dosing: ${(progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Color(0xFFD7EFD9), fontSize: 12),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _processStateCard() {
    return _panel(
      child: StreamBuilder<String>(
        stream: _nutrimixService.processStateStream(),
        builder: (context, stateSnap) {
          final state = (stateSnap.data ?? 'idle').toLowerCase();
          final activeStep = _activeStepByState(state);
          return StreamBuilder<int>(
            stream: _nutrimixService.servoDurationStream(),
            builder: (context, servoSnap) {
              final servoDuration = servoSnap.data ?? 5;
              return StreamBuilder<int>(
                stream: _nutrimixService.trimmerDurationStream(),
                builder: (context, trimmerSnap) {
                  final trimmerDuration = trimmerSnap.data ?? 20;
                  final steps = [
                    'Input Target',
                    'Screw Dosing',
                    'Servo Turun (${servoDuration}s)',
                    'Trimmer ON (${trimmerDuration}s)',
                    'Selesai',
                  ];

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Status Proses',
                        style: TextStyle(
                          color: Color(0xFFF1F8E9),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'State ESP: $state',
                        style: const TextStyle(color: Color(0xFFD7EFD9), fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      ...steps.asMap().entries.map((entry) {
                        final index = entry.key;
                        final isDone = index < activeStep;
                        final isActive = index == activeStep;
                        final color =
                            isDone || isActive ? const Color(0xFF81C784) : const Color(0x66FFFFFF);

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isDone || isActive ? color : Colors.transparent,
                                  border: Border.all(color: color),
                                ),
                                child: isDone
                                    ? const Icon(Icons.check, size: 12, color: Color(0xFF0F2A1C))
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  entry.value,
                                  style: TextStyle(
                                    color: isActive ? const Color(0xFFF1F8E9) : const Color(0xFFD7EFD9),
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _actuatorCard() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Monitoring Aktuator',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _boolTile(
                  title: 'Relay Screw',
                  stream: _nutrimixService.screwRelayStream(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _boolTile(
                  title: 'Relay Trimmer',
                  stream: _nutrimixService.trimmerRelayStream(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          StreamBuilder<int>(
            stream: _nutrimixService.servoAngleStream(),
            builder: (context, snap) {
              final angle = (snap.data ?? 0).toDouble();
              return _metricBox(
                title: 'Posisi Servo',
                value: '${angle.toStringAsFixed(0)} deg',
                icon: Icons.settings_input_component_outlined,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tuningCard() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pengaturan Tolerance',
            style: TextStyle(
              color: Color(0xFFF1F8E9),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Zero tolerance dan target tolerance bisa diubah manual dari sini.',
            style: TextStyle(color: Color(0xFFD7EFD9), fontSize: 12),
          ),
          const SizedBox(height: 10),
          _ConfigDoubleSlider(
            title: 'Zero Tolerance',
            min: 0,
            max: 20,
            divisions: 200,
            unit: 'g',
            stream: _nutrimixService.zeroToleranceStream(),
            onSubmit: (value) async {
              await _nutrimixService.setZeroTolerance(value);
              await ActivityLoggerService.log(
                action: 'nutrimix.config.zero_tolerance',
                module: 'nutrimix',
                deviceId: widget.deviceId,
                description: 'Ubah zero tolerance menjadi ${value}g pada device ${widget.deviceId}',
                metadata: {'zero_tol_g': value},
              );
            },
          ),
          const SizedBox(height: 8),
          _ConfigDoubleSlider(
            title: 'Target Tolerance',
            min: 0,
            max: 20,
            divisions: 200,
            unit: 'g',
            stream: _nutrimixService.targetToleranceStream(),
            onSubmit: (value) async {
              await _nutrimixService.setTargetTolerance(value);
              await ActivityLoggerService.log(
                action: 'nutrimix.config.target_tolerance',
                module: 'nutrimix',
                deviceId: widget.deviceId,
                description: 'Ubah target tolerance menjadi ${value}g pada device ${widget.deviceId}',
                metadata: {'target_tol_g': value},
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _metricBox({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF2E7D32),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: const Color(0x3366BB6A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: const Color(0xFFB9E5BE), size: 17),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Color(0xFFD7EFD9), fontSize: 11),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    color: Color(0xFFF1F8E9),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _boolTile({
    required String title,
    required Stream<bool> stream,
  }) {
    return StreamBuilder<bool>(
      stream: stream,
      builder: (context, snap) {
        final on = snap.data ?? false;
        return Container(
          padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: on ? const Color(0x334CAF50) : const Color(0x33222C25),
        border: Border.all(
          color: on ? const Color(0x6681C784) : const Color(0x66FFFFFF),
        ),
          ),
          child: Row(
            children: [
              Icon(
                on ? Icons.power : Icons.power_off,
                color: on ? const Color(0xFFB9E5BE) : const Color(0xFFD7EFD9),
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$title: ${on ? 'ON' : 'OFF'}',
                  style: const TextStyle(
                    color: Color(0xFFF1F8E9),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 7, 68, 10),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
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

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value == null) return false;
    final str = value.toString().toLowerCase();
    return str == 'true' || str == '1' || str == 'on';
  }

  int _activeStepByState(String state) {
    switch (state) {
      case 'dosing':
      case 'screw_on':
        return 1;
      case 'servo_open':
      case 'servo_down':
        return 2;
      case 'trimmer_on':
      case 'trimming':
        return 3;
      case 'done':
      case 'complete':
        return 4;
      case 'idle':
      default:
        return 0;
    }
  }
}

class _ConfigIntSlider extends StatefulWidget {
  final String title;
  final int min;
  final int max;
  final String unit;
  final Stream<int> stream;
  final Future<void> Function(int value) onSubmit;

  const _ConfigIntSlider({
    required this.title,
    required this.min,
    required this.max,
    required this.unit,
    required this.stream,
    required this.onSubmit,
  });

  @override
  State<_ConfigIntSlider> createState() => _ConfigIntSliderState();
}

class _ConfigIntSliderState extends State<_ConfigIntSlider> {
  double? _draftValue;
  bool _editing = false;
  final TextEditingController _manualController = TextEditingController();
  final FocusNode _manualFocusNode = FocusNode();

  @override
  void dispose() {
    _manualController.dispose();
    _manualFocusNode.dispose();
    super.dispose();
  }

  Future<void> _applyManual() async {
    final parsed = int.tryParse(_manualController.text.trim());
    if (parsed == null) return;
    final clamped = parsed.clamp(widget.min, widget.max);
    await widget.onSubmit(clamped);
    if (!mounted) return;
    setState(() {
      _editing = false;
      _draftValue = null;
    });
    _manualFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: widget.stream,
      builder: (context, snap) {
        final remoteValue = (snap.data ?? widget.min).clamp(widget.min, widget.max);
        final currentValue = (_editing ? _draftValue?.round() : remoteValue) ?? remoteValue;
        if (!_manualFocusNode.hasFocus) {
          _manualController.text = currentValue.toString();
        }

        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: const Color(0x33222C25),
            border: Border.all(color: const Color(0x55FFFFFF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        color: Color(0xFFD7EFD9),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$currentValue ${widget.unit}',
                    style: const TextStyle(
                      color: Color(0xFFF1F8E9),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              Slider(
                value: currentValue.toDouble(),
                min: widget.min.toDouble(),
                max: widget.max.toDouble(),
                divisions: widget.max - widget.min,
                onChanged: (value) {
                  setState(() {
                    _editing = true;
                    _draftValue = value;
                  });
                },
                onChangeEnd: (value) async {
                  await widget.onSubmit(value.round());
                  if (!mounted) return;
                  setState(() {
                    _editing = false;
                    _draftValue = null;
                  });
                },
              ),
              const SizedBox(height: 4),
              const Text(
                'Input manual:',
                style: TextStyle(
                  color: Color(0xFFD7EFD9),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manualController,
                      focusNode: _manualFocusNode,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Color(0xFFF1F8E9), fontSize: 13),
                      onSubmitted: (_) => _applyManual(),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        suffixText: widget.unit,
                        suffixStyle: const TextStyle(color: Color(0xFFD7EFD9)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.06),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                          borderSide: BorderSide(color: Color(0xFF81C784)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _applyManual,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE8F5E9),
                      side: const BorderSide(color: Color(0x66FFFFFF)),
                    ),
                    child: const Text('Set'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConfigDoubleSlider extends StatefulWidget {
  final String title;
  final double min;
  final double max;
  final int divisions;
  final String unit;
  final Stream<double> stream;
  final Future<void> Function(double value) onSubmit;

  const _ConfigDoubleSlider({
    required this.title,
    required this.min,
    required this.max,
    required this.divisions,
    required this.unit,
    required this.stream,
    required this.onSubmit,
  });

  @override
  State<_ConfigDoubleSlider> createState() => _ConfigDoubleSliderState();
}

class _ConfigDoubleSliderState extends State<_ConfigDoubleSlider> {
  double? _draftValue;
  bool _editing = false;
  final TextEditingController _manualController = TextEditingController();
  final FocusNode _manualFocusNode = FocusNode();

  @override
  void dispose() {
    _manualController.dispose();
    _manualFocusNode.dispose();
    super.dispose();
  }

  Future<void> _applyManual() async {
    final parsed = double.tryParse(_manualController.text.trim());
    if (parsed == null) return;
    final clamped = parsed.clamp(widget.min, widget.max);
    await widget.onSubmit(clamped);
    if (!mounted) return;
    setState(() {
      _editing = false;
      _draftValue = null;
    });
    _manualFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: widget.stream,
      builder: (context, snap) {
        final remoteValue = (snap.data ?? widget.min).clamp(widget.min, widget.max);
        final currentValue = (_editing ? _draftValue : remoteValue) ?? remoteValue;
        if (!_manualFocusNode.hasFocus) {
          _manualController.text = currentValue.toStringAsFixed(1);
        }

        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: const Color(0x33222C25),
            border: Border.all(color: const Color(0x55FFFFFF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        color: Color(0xFFD7EFD9),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${currentValue.toStringAsFixed(1)} ${widget.unit}',
                    style: const TextStyle(
                      color: Color(0xFFF1F8E9),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              Slider(
                value: currentValue,
                min: widget.min,
                max: widget.max,
                divisions: widget.divisions,
                onChanged: (value) {
                  setState(() {
                    _editing = true;
                    _draftValue = value;
                  });
                },
                onChangeEnd: (value) async {
                  await widget.onSubmit(value);
                  if (!mounted) return;
                  setState(() {
                    _editing = false;
                    _draftValue = null;
                  });
                },
              ),
              const SizedBox(height: 4),
              const Text(
                'Input manual:',
                style: TextStyle(
                  color: Color(0xFFD7EFD9),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manualController,
                      focusNode: _manualFocusNode,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Color(0xFFF1F8E9), fontSize: 13),
                      onSubmitted: (_) => _applyManual(),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        suffixText: widget.unit,
                        suffixStyle: const TextStyle(color: Color(0xFFD7EFD9)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.06),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                          borderSide: BorderSide(color: Color(0xFF81C784)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _applyManual,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE8F5E9),
                      side: const BorderSide(color: Color(0x66FFFFFF)),
                    ),
                    child: const Text('Set'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniTag extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MiniTag({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFFB9E5BE)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFFE8F5E9),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
