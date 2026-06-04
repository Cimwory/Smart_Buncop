import 'package:flutter/material.dart';
import '../controllers/plant_controller.dart';
import '../domain/repositories/plant_repository.dart';
import '../services/mqtt_device_service.dart';
import '../services/activity_logger_service.dart';
import '../widgets/form_section_card.dart';
import '../widgets/labeled_slider.dart';
import '../widgets/watering_time_tile.dart';

class AddPlantPage extends StatefulWidget {
  final String deviceId;
  final String? plantId;
  final Map<String, dynamic>? plantData;

  const AddPlantPage({
    super.key,
    required this.deviceId,
    this.plantId,
    this.plantData,
  });

  @override
  State<AddPlantPage> createState() => _AddPlantPageState();
}

class _AddPlantPageState extends State<AddPlantPage> {
  late final PlantRepository plantRepository;
  final PlantController controller = PlantController();

  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController tempMinCtrl = TextEditingController();
  final TextEditingController tempMaxCtrl = TextEditingController();
  final TextEditingController darkDaysCtrl = TextEditingController();
  final TextEditingController lightDaysCtrl = TextEditingController();

  /// The form state object that keeps all editable values.
  late PlantFormData formData;

  /// grow light Barina T8 full spectrum (static metadata)
  final int kelvin = 6500;

  double _snapPwmStep(double value) {
    if (value <= 0) return 0;
    final step = (value / 10).round() * 10;
    return step.clamp(0, 100).toDouble();
  }

  DateTime _dateOnly(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  Future<void> _pickCycleStartDate() async {
    final now = DateTime.now();
    final current = _dateOnly(formData.cycleStartDate);
    final firstDate = DateTime(now.year - 5, 1, 1);
    final lastDate = DateTime(now.year + 5, 12, 31);

    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: "Tanggal Mulai Siklus",
      fieldHintText: "YYYY-MM-DD",
    );

    if (picked == null) return;

    setState(() {
      formData.cycleStartDate = _dateOnly(picked);
    });
  }

  Future<void> _pickLightStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: formData.lightStartTime,
    );
    if (picked == null) return;
    setState(() => formData.lightStartTime = picked);
  }

  Future<void> _pickLightEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: formData.lightEndTime,
    );
    if (picked == null) return;
    setState(() => formData.lightEndTime = picked);
  }

  @override
  void initState() {
    super.initState();
    plantRepository = MqttDeviceService(deviceId: widget.deviceId);

    final isEdit = widget.plantId != null;
    ActivityLoggerService.log(
      action: isEdit ? 'screen.open.edit_plant' : 'screen.open.add_plant',
      module: 'inkubator',
      deviceId: widget.deviceId,
      description: isEdit
          ? 'Membuka halaman edit tanaman "${widget.plantId}" pada device ${widget.deviceId}'
          : 'Membuka halaman tambah tanaman pada device ${widget.deviceId}',
      metadata: isEdit ? {'plant_id': widget.plantId} : null,
    );

    // populate form data from existing plant if provided
    if (widget.plantData != null) {
      formData = PlantFormData.fromMap(widget.plantData!);
    } else {
      formData = PlantFormData();
    }

    nameCtrl.text = formData.name;
    tempMinCtrl.text = formData.tempMin.toStringAsFixed(1);
    tempMaxCtrl.text = formData.tempMax.toStringAsFixed(1);
    darkDaysCtrl.text = formData.darkDays.toString();
    lightDaysCtrl.text = formData.lightDays.toString();
  }

  // =====================================
  // SAVE PLANT
  // =====================================

  Future<void> save() async {
    if (nameCtrl.text.trim().isEmpty) return;

    formData.name = nameCtrl.text.trim();
    formData.darkDays = int.tryParse(darkDaysCtrl.text.trim()) ?? formData.darkDays;
    formData.lightDays = int.tryParse(lightDaysCtrl.text.trim()) ?? formData.lightDays;
    if (formData.darkDays < 1) formData.darkDays = 1;
    if (formData.lightDays < 1) formData.lightDays = 1;

    // Keep temperature values from slider state (formData).
    final plant = formData.toMap();
    plant["light_kelvin"] = kelvin;

    try {
      final isEdit = widget.plantId != null;
      if (isEdit) {
        await plantRepository.updatePlant(widget.plantId!, plant);
      } else {
        await plantRepository.addPlant(plant);
      }

      await ActivityLoggerService.log(
        action: isEdit ? 'plant.update' : 'plant.create',
        module: 'inkubator',
        deviceId: widget.deviceId,
        description: isEdit
            ? 'Mengupdate tanaman "${formData.name}" (${widget.plantId}) pada device ${widget.deviceId}'
            : 'Menambahkan tanaman baru "${formData.name}" pada device ${widget.deviceId}',
        metadata: {
          if (isEdit) 'plant_id': widget.plantId,
          'plant_name': formData.name,
          'temp_min': formData.tempMin,
          'temp_max': formData.tempMax,
          'dark_days': formData.darkDays,
          'light_days': formData.lightDays,
          'start_phase': formData.cycleStartPhase,
        },
      );

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Gagal menyimpan tanaman: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.plantId != null;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.green.shade900,
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Image.asset(
              "assets/logo/vitaroot.png",
              height: 26,
            ),
            const SizedBox(width: 10),
            Text(
              isEdit ? "Edit Tanaman" : "Tambah Tanaman",
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: Text(
                isEdit ? "Update Tanaman" : "Simpan Tanaman",
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF66BB6A),
                foregroundColor: const Color.fromARGB(255, 26, 61, 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              onPressed: save,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF1B5E20),
              Color(0xFF66BB6A),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _plantInfoCard(),
                const SizedBox(height: 14),
                _lightingCard(),
                const SizedBox(height: 14),
                _wateringScheduleCard(),
                const SizedBox(height: 14),
                _sprayerDurationCard(),
                const SizedBox(height: 14),
                _temperatureSectionCard(),
                const SizedBox(height: 80),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _temperatureSectionCard() {
    return FormSectionCard(
      title: "Suhu Optimal",
      icon: Icons.thermostat_outlined,
      child: Column(
        children: [
          _temperatureCard(
            title: "Suhu Minimum",
            value: formData.tempMin,
            min: 10,
            max: 35,
            onChanged: (v) {
              setState(() {
                formData.tempMin = v;

                if (formData.tempMax < v) {
                  formData.tempMax = v;
                }
              });
            },
          ),
          const SizedBox(height: 14),
          _temperatureCard(
            title: "Suhu Maksimum",
            value: formData.tempMax,
            min: 15,
            max: 45,
            onChanged: (v) {
              setState(() {
                formData.tempMax = v;

                if (formData.tempMin > v) {
                  formData.tempMin = v;
                }
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _plantInfoCard() {
    return FormSectionCard(
      title: "Informasi Tanaman",
      icon: Icons.eco_outlined,
      child: Column(
        children: [
          TextField(
            controller: nameCtrl,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
            ),
            decoration: InputDecoration(
              labelText: "Nama Tanaman",
              labelStyle: const TextStyle(
                color: Color(0xFFC8E6C9),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Colors.white.withOpacity(0.2),
                ),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(
                  color: Color(0xFF2E7D32),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              "Mode Otomatis Tanaman",
              style: TextStyle(
                color: Color(0xFFF1F8E9),
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: const Text(
              "Lampu & sprayer mengikuti preset",
              style: TextStyle(
                color: Color(0xFFC8E6C9),
              ),
            ),
            activeColor: const Color(0xFF2E7D32),
            value: formData.auto,
            onChanged: (v) => setState(() => formData.auto = v),
          ),
        ],
      ),
    );
  }

  Widget _temperatureCard({
    required String title,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /// TITLE + VALUE
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE8F5E9),
              ),
            ),
            const Spacer(),
            Text(
              "${value.toStringAsFixed(1)} °C",
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF81C784),
              ),
            ),
          ],
        ),

        const SizedBox(height: 6),

        /// SLIDER
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFF2E7D32),
            inactiveTrackColor: Colors.white24,
            thumbColor: const Color(0xFF81C784),
            overlayColor: const Color(0xFF81C784).withOpacity(0.2),
            trackHeight: 4,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) * 10).toInt(),
            label: "${value.toStringAsFixed(1)} °C",
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _lightingCard() {
    return FormSectionCard(
      title: "Pencahayaan",
      icon: Icons.lightbulb_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LabeledSlider(
            label: "Kecerahan Lampu",
            value: formData.pwm,
            min: 0,
            max: 100,
            divisions: 10,
            unit: "%",
            onChanged: (v) => setState(() => formData.pwm = _snapPwmStep(v)),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 123, 231, 136).withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              "Grow Light Full Spectrum (6500K)",
              style: TextStyle(
                color: Color(0xFFC8E6C9),
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              _presetChip("Seedling", 30),
              _presetChip("Vegetative", 60),
              _presetChip("Flowering", 80),
              _presetChip("Maximum", 100),
            ],
          ),
          const SizedBox(height: 14),
          _lightCycleCard(),
        ],
      ),
    );
  }

  Widget _lightCycleCard() {
    final date = formData.cycleStartDate;
    final startDateLabel =
        "${date.year.toString().padLeft(4, '0')}-"
        "${date.month.toString().padLeft(2, '0')}-"
        "${date.day.toString().padLeft(2, '0')}";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x332E7D32),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Siklus Lampu Otomatis",
            style: TextStyle(
              color: Color(0xFFE8F5E9),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            formData.cycleStartPhase == 'light'
                ? "Siklus dimulai dari fase terang (lampu ON), lalu berlanjut ke gelap."
                : "Siklus dimulai dari fase gelap (lampu OFF), lalu berlanjut ke terang.",
            style: TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: formData.cycleStartPhase == 'light' ? 'light' : 'dark',
            dropdownColor: const Color(0xFF2E7D32),
            style: const TextStyle(color: Color(0xFFE8F5E9)),
            decoration: InputDecoration(
              labelText: "Fase Awal Saat Mulai",
              labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(10)),
                borderSide: BorderSide(color: Color(0xFF81C784)),
              ),
            ),
            items: const [
              DropdownMenuItem(
                value: 'dark',
                child: Text('Mulai dari masa gelap'),
              ),
              DropdownMenuItem(
                value: 'light',
                child: Text('Mulai dari masa terang'),
              ),
            ],
            onChanged: (value) {
              setState(() {
                formData.cycleStartPhase = value == 'light' ? 'light' : 'dark';
              });
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: darkDaysCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Color(0xFFE8F5E9)),
                  decoration: InputDecoration(
                    labelText: "Masa Gelap (hari)",
                    labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
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
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: lightDaysCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Color(0xFFE8F5E9)),
                  decoration: InputDecoration(
                    labelText: "Masa Terang (hari)",
                    labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
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
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickLightStartTime,
                  icon: const Icon(Icons.light_mode_outlined),
                  label: Text(
                    "Lampu ON ${formData.lightStartTime.format(context)}",
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE8F5E9),
                    side: const BorderSide(color: Color(0x66FFFFFF)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickLightEndTime,
                  icon: const Icon(Icons.bedtime_outlined),
                  label: Text(
                    "Lampu OFF ${formData.lightEndTime.format(context)}",
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE8F5E9),
                    side: const BorderSide(color: Color(0x66FFFFFF)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickCycleStartDate,
            icon: const Icon(Icons.calendar_month_outlined),
            label: Text("Tanggal Mulai: $startDateLabel"),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFE8F5E9),
              side: const BorderSide(color: Color(0x66FFFFFF)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wateringScheduleCard() {
    return FormSectionCard(
      title: "Jadwal Penyiraman",
      icon: Icons.water_drop_outlined,
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Tambah Waktu Siram"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF66BB6A),
                foregroundColor: const Color(0xFF0F2A1D),
              ),
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.now(),
                );

                if (picked != null) {
                  setState(() {
                    formData.wateringTimes.add(picked);

                    formData.wateringTimes.sort(
                      (a, b) =>
                          (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute),
                    );
                  });
                }
              },
            ),
          ),
          const SizedBox(height: 8),
          ...formData.wateringTimes.asMap().entries.map((e) {
            return WateringTimeTile(
              index: e.key,
              time: e.value,
              onEdit: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: e.value,
                );
                if (picked == null) return;
                setState(() {
                  formData.wateringTimes[e.key] = picked;
                  formData.wateringTimes.sort(
                    (a, b) =>
                        (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute),
                  );
                });
              },
              onDelete: () {
                setState(() {
                  formData.wateringTimes.removeAt(e.key);
                });
              },
            );
          }),
        ],
      ),
    );
  }

  Widget _sprayerDurationCard() {
    return FormSectionCard(
      title: "Durasi Sprayer",
      icon: Icons.timer_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "${formData.wateringDuration} detik",
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF1F8E9),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF2E7D32),
              inactiveTrackColor: Colors.white.withOpacity(0.15),
              thumbColor: const Color(0xFF81C784),
              overlayColor: const Color(0xFF81C784).withOpacity(0.15),
              trackHeight: 4,
            ),
            child: Slider(
              min: 1,
              max: 120,
              divisions: 119,
              value: formData.wateringDuration.toDouble(),
              onChanged: (v) =>
                  setState(() => formData.wateringDuration = v.toInt()),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    tempMinCtrl.dispose();
    tempMaxCtrl.dispose();
    darkDaysCtrl.dispose();
    lightDaysCtrl.dispose();
    super.dispose();
  }

  // =====================================
  // PRESET CHIP
  // =====================================

  Widget _presetChip(String label, double value) {
    final selected = formData.pwm.round() == value;

    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: selected
              ? const Color.fromARGB(255, 254, 253, 253)
              : const Color.fromARGB(255, 7, 54, 11),
          fontWeight: FontWeight.w500,
        ),
      ),

      selected: selected,

      /// warna aktif (tidak terlalu terang)
      selectedColor: const Color(0xFF66BB6A),

      /// warna idle → ganti dari putih ke green surface
      backgroundColor: const Color(0xFF81C784).withOpacity(0.10),

      /// border soft
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: const Color(0xFF81C784).withOpacity(0.18),
        ),
      ),

      onSelected: (_) {
        setState(() {
          formData.pwm = _snapPwmStep(value);
        });
      },
    );
  }
}
