import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/repositories/device_repository.dart';
import '../domain/repositories/plant_repository.dart';
import '../services/notification_service.dart';
import '../services/activity_logger_service.dart';

class InkubatorController {
  final DeviceRepository deviceRepository;
  final PlantRepository plantRepository;

  InkubatorController({
    required this.deviceRepository,
    required this.plantRepository,
  });

  final ValueNotifier<String> timeNow = ValueNotifier("");
  final ValueNotifier<int> sprayerCountdown = ValueNotifier(0);
  final ValueNotifier<double> lampPWM = ValueNotifier(0);
  final ValueNotifier<int> manualSprayerDuration = ValueNotifier(10);
  final ValueNotifier<String> currentMode = ValueNotifier("manual");
  final ValueNotifier<bool> hasActivePlant = ValueNotifier(false);
  final ValueNotifier<double> minTemp = ValueNotifier(0);
  final ValueNotifier<double> maxTemp = ValueNotifier(0);
  final ValueNotifier<List<TimeOfDay>> manualSprayerTimes =
      ValueNotifier(<TimeOfDay>[]);
  final ValueNotifier<String> autoLightPhaseInfo =
      ValueNotifier("Siklus lampu: -");
  final ValueNotifier<int> plantAgeDays = ValueNotifier(0);
  final ValueNotifier<int> darkPhaseDay = ValueNotifier(0);
  final ValueNotifier<int> lightPhaseDay = ValueNotifier(0);
  final ValueNotifier<String> currentPlantPhase = ValueNotifier("-");
  final ValueNotifier<String> nextSprayerCountdownInfo =
      ValueNotifier("Jadwal sprayer berikutnya: -");

  Timer? _clockTimer;
  Timer? _sprayerTimer;
  Timer? _autoLightTimer;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  String _lastMode = "";
  bool _lastLamp = false;
  bool _lastFan = false;
  bool _lastSprayer = false;
  bool _initializedRelays = false;
  String _activePlantId = "";
  String _lastCycleKey = "";
  bool? _lastAutoLampState;
  int? _lastAutoPwm;

  int _snapLampStep(double value) {
    if (value <= 0) return 0;
    final step = (value / 10).round() * 10;
    return step.clamp(0, 100);
  }

  void init() {
    _setupListeners();
  }

  void _setupListeners() {
    startClock();
    _listenLampPWM();
    _listenSprayerRelay();
    _listenSprayerDuration();
    _listenStatus();
    _listenMode();
    _listenRelays();
    _listenActivePlantTemp();
    _listenManualSprayerTimes();
    _startAutoLightEvaluator();
  }

  void startClock() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      timeNow.value =
          "${now.hour.toString().padLeft(2, '0')}:"
          "${now.minute.toString().padLeft(2, '0')}:"
          "${now.second.toString().padLeft(2, '0')}";
    });
  }

  void startSprayerCountdown(int seconds) {
    _sprayerTimer?.cancel();
    sprayerCountdown.value = seconds;
    _sprayerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (sprayerCountdown.value <= 1) {
        stopSprayerCountdown();
      } else {
        sprayerCountdown.value--;
      }
    });
  }

  void stopSprayerCountdown() {
    _sprayerTimer?.cancel();
    _sprayerTimer = null;
    sprayerCountdown.value = 0;
  }

  void _listenStatus() {
    bool lastOnline = true;
    _subscriptions.add(
      deviceRepository.espOnlineStream().listen((online) {
        if (online != lastOnline) {
          lastOnline = online;
          NotificationService.show(
            online ? "ESP Online" : "ESP Offline",
            online
                ? "ESP32 inkubator terhubung kembali"
                : "ESP32 inkubator terputus",
          );
        }
      }),
    );
  }

  void _listenLampPWM() {
    _subscriptions.add(
      deviceRepository.lampPwmStream().listen((v) {
        if (v != null) {
          lampPWM.value = _snapLampStep(v.toDouble()).toDouble();
        }
      }),
    );
  }

  void _listenSprayerRelay() {
    _subscriptions.add(
      deviceRepository.relayValueStream("sprayer").listen((on) {
        if (on && sprayerCountdown.value == 0) {
          startSprayerCountdown(manualSprayerDuration.value);
        }
        if (!on && sprayerCountdown.value != 0) {
          stopSprayerCountdown();
        }
      }),
    );
  }

  void _listenSprayerDuration() {
    _subscriptions.add(
      deviceRepository.sprayerDurationStream().listen((v) {
        if (v != null) {
          manualSprayerDuration.value = v;
        }
      }),
    );
  }

  void _listenMode() {
    _subscriptions.add(
      deviceRepository.modeStream().listen((mode) {
        if (mode == _lastMode) return;
        _lastMode = mode;
        currentMode.value = mode;
        NotificationService.show(
          "Mode berubah",
          mode == "auto" ? "Mode otomatis aktif" : "Mode manual aktif",
        );

        if (mode != "auto") {
          autoLightPhaseInfo.value = "Siklus lampu: nonaktif (mode manual)";
          nextSprayerCountdownInfo.value = "Jadwal sprayer berikutnya: nonaktif (mode manual)";
          _lastCycleKey = "";
          _lastAutoLampState = null;
          _lastAutoPwm = null;
        }

        _applyAutoLightCycle();
      }),
    );
  }

  void _listenRelays() {
    _subscriptions.add(
      deviceRepository.relayValueStream("lamp").listen((on) async {
        if (!_initializedRelays) {
          _lastLamp = on;
          return;
        }
        if (on != _lastLamp) {
          _lastLamp = on;
          final mode = await deviceRepository.getMode();
          if (mode == "auto") {
            NotificationService.show(
              "Lampu",
              on ? "Lampu menyala (AUTO)" : "Lampu mati (AUTO)",
            );
          }
        }
      }),
    );

    _subscriptions.add(
      deviceRepository.relayValueStream("fan").listen((on) async {
        if (!_initializedRelays) {
          _lastFan = on;
          return;
        }
        if (on != _lastFan) {
          _lastFan = on;
          final mode = await deviceRepository.getMode();
          if (mode == "auto") {
            NotificationService.show(
              "Kipas",
              on ? "Kipas menyala (AUTO)" : "Kipas mati (AUTO)",
            );
          }
        }
      }),
    );

    _subscriptions.add(
      deviceRepository.relayValueStream("sprayer").listen((on) async {
        if (!_initializedRelays) {
          _lastSprayer = on;
          _initializedRelays = true;
          return;
        }
        if (on != _lastSprayer) {
          _lastSprayer = on;
          final mode = await deviceRepository.getMode();
          if (mode == "auto") {
            NotificationService.show(
              "Sprayer AUTO",
              on ? "Sprayer aktif" : "Sprayer selesai",
            );
          } else if (mode == "manual" && on) {
            NotificationService.show(
              "Sprayer Manual",
              "Sprayer manual diaktifkan",
            );
          }
        }
      }),
    );
  }

  void _listenActivePlantTemp() {
    _subscriptions.add(
      deviceRepository.activePlantStream().listen((plantId) async {
        _activePlantId = plantId;
        if (plantId.isEmpty) {
          hasActivePlant.value = false;
          minTemp.value = 0;
          maxTemp.value = 0;
          plantAgeDays.value = 0;
          darkPhaseDay.value = 0;
          lightPhaseDay.value = 0;
          currentPlantPhase.value = "-";
          nextSprayerCountdownInfo.value = "Jadwal sprayer berikutnya: -";
          autoLightPhaseInfo.value = "Siklus lampu: belum ada tanaman aktif";
          _lastCycleKey = "";
          _lastAutoLampState = null;
          _lastAutoPwm = null;
          return;
        }
        final data = await plantRepository.getTempOptimal(plantId);
        if (data == null) {
          hasActivePlant.value = false;
          return;
        }
        hasActivePlant.value = true;
        minTemp.value = (data["min"] as num).toDouble();
        maxTemp.value = (data["max"] as num).toDouble();

        _applyAutoLightCycle();
      }),
    );
  }

  void _startAutoLightEvaluator() {
    _autoLightTimer?.cancel();
    _autoLightTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _applyAutoLightCycle();
    });
    _applyAutoLightCycle();
  }

  Future<void> _applyAutoLightCycle() async {
    if (currentMode.value != "auto") return;
    if (_activePlantId.isEmpty) return;

    final plantData = await plantRepository.getPlantById(_activePlantId);
    if (plantData == null) return;

    final lightCycleRaw = plantData["light_cycle"];
    final lightCycle =
        lightCycleRaw is Map ? Map<String, dynamic>.from(lightCycleRaw) : {};
    final lightingRaw = plantData["lighting"];
    final lighting = lightingRaw is Map ? Map<String, dynamic>.from(lightingRaw) : {};

    final darkDays =
        (((lightCycle["dark_days"] as num?)?.toInt() ?? 7).clamp(1, 365))
            .toInt();
    final lightDays =
        (((lightCycle["light_days"] as num?)?.toInt() ?? 7).clamp(1, 365))
            .toInt();

    final startDateRaw = lightCycle["start_date"]?.toString() ?? "";
    final startPhaseRaw = (lightCycle["start_phase"]?.toString() ?? "dark")
        .trim()
        .toLowerCase();
    final startWithLight = startPhaseRaw == "light";
    final parsedStartDate = DateTime.tryParse(startDateRaw);
    final fallbackDate = DateTime.now();
    final startDate = DateTime(
      (parsedStartDate ?? fallbackDate).year,
      (parsedStartDate ?? fallbackDate).month,
      (parsedStartDate ?? fallbackDate).day,
    );

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    var elapsedDays = today.difference(startDate).inDays;
    if (elapsedDays < 0) {
      elapsedDays = 0;
    }

    final totalCycleDays = darkDays + lightDays;
    final cycleDayIndex = elapsedDays % totalCycleDays;
    final inDarkPhase = startWithLight
        ? cycleDayIndex >= lightDays
        : cycleDayIndex < darkDays;
    final phase = inDarkPhase ? "gelap" : "terang";
    final phaseDay = startWithLight
        ? (inDarkPhase ? (cycleDayIndex - lightDays + 1) : (cycleDayIndex + 1))
        : (inDarkPhase ? (cycleDayIndex + 1) : (cycleDayIndex - darkDays + 1));
    final phaseLength = inDarkPhase ? darkDays : lightDays;
    final startTime = (lighting["start_time"]?.toString() ?? "06:00").trim();
    final endTime = (lighting["end_time"]?.toString() ?? "17:00").trim();

    autoLightPhaseInfo.value =
        "Siklus lampu: $phase (hari ke-$phaseDay/$phaseLength), jam $startTime-$endTime";
    plantAgeDays.value = elapsedDays + 1;
    darkPhaseDay.value = inDarkPhase ? phaseDay : 0;
    lightPhaseDay.value = inDarkPhase ? 0 : phaseDay;
    currentPlantPhase.value = phase;
    nextSprayerCountdownInfo.value = _buildNextSprayerInfo(plantData, now);

    final cycleKey = "$phase|$phaseDay|$phaseLength|${today.toIso8601String()}";
    if (_lastCycleKey != cycleKey) {
      _lastCycleKey = cycleKey;
      NotificationService.show(
        "Siklus lampu otomatis",
        inDarkPhase
            ? "Masuk masa gelap (lampu OFF)"
            : "Masuk masa terang (lampu ON)",
      );
    }

    final nowHm = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    final inLightWindow = _isNowWithinRange(nowHm, startTime, endTime);
    final shouldLampOn = !inDarkPhase && inLightWindow;
    if (_lastAutoLampState != shouldLampOn) {
      _lastAutoLampState = shouldLampOn;
      await deviceRepository.setRelay("lamp", shouldLampOn);
      await ActivityLoggerService.log(
        action: 'inkubator.relay.auto_toggle',
        module: 'inkubator',
        deviceId: deviceRepository.deviceId,
        description: 'System (auto mode) mengubah relay lamp menjadi ${shouldLampOn ? "ON" : "OFF"} — fase $phase hari ke-$phaseDay',
        metadata: {
          'relay': 'lamp',
          'state': shouldLampOn,
          'phase': phase,
          'phase_day': phaseDay,
          'trigger': 'auto_light_cycle',
        },
      );
    }

    if (!shouldLampOn) return;

    final pwm = ((plantData["light_pwm"] as num?)?.toDouble() ?? 60.0);
    final snapped = _snapLampStep(pwm);
    if (_lastAutoPwm != snapped) {
      _lastAutoPwm = snapped;
      await deviceRepository.setLampPWM(snapped);
      await ActivityLoggerService.log(
        action: 'inkubator.lamp_pwm.auto_change',
        module: 'inkubator',
        deviceId: deviceRepository.deviceId,
        description: 'System (auto mode) mengubah kecerahan lampu menjadi $snapped% — fase $phase',
        metadata: {
          'lamp_pwm': snapped,
          'phase': phase,
          'trigger': 'auto_light_cycle',
        },
      );
    }
  }

  bool _isNowWithinRange(String nowTime, String startTime, String endTime) {
    if (startTime.isEmpty || endTime.isEmpty) return false;
    if (startTime.compareTo(endTime) <= 0) {
      return nowTime.compareTo(startTime) >= 0 && nowTime.compareTo(endTime) < 0;
    }
    // Handle over-midnight range.
    return nowTime.compareTo(startTime) >= 0 || nowTime.compareTo(endTime) < 0;
  }

  String _buildNextSprayerInfo(Map<String, dynamic> plantData, DateTime now) {
    final wateringRaw = plantData["watering"];
    if (wateringRaw is! Map) {
      return "Jadwal sprayer berikutnya: belum tersedia";
    }

    final watering = Map<String, dynamic>.from(wateringRaw);
    final timesRaw = watering["times"];
    final List<String> times = [];

    if (timesRaw is List) {
      for (final value in timesRaw) {
        if (value == null) continue;
        final token = value.toString().trim();
        if (_isValidHHMM(token)) times.add(token);
      }
    }

    if (times.isEmpty) {
      return "Jadwal sprayer berikutnya: belum tersedia";
    }

    Duration? bestDiff;
    String? bestTime;
    for (final token in times) {
      final parts = token.split(":");
      final hour = int.tryParse(parts[0]) ?? 0;
      final minute = int.tryParse(parts[1]) ?? 0;
      var target = DateTime(now.year, now.month, now.day, hour, minute);
      if (!target.isAfter(now)) {
        target = target.add(const Duration(days: 1));
      }
      final diff = target.difference(now);
      if (bestDiff == null || diff < bestDiff) {
        bestDiff = diff;
        bestTime = token;
      }
    }

    if (bestDiff == null || bestTime == null) {
      return "Jadwal sprayer berikutnya: -";
    }

    final totalMinutes = bestDiff.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours > 0) {
      return "Jadwal sprayer berikutnya: $bestTime (dalam ${hours}j ${minutes}m)";
    }
    return "Jadwal sprayer berikutnya: $bestTime (dalam ${minutes}m)";
  }

  bool _isValidHHMM(String value) {
    final parts = value.split(":");
    if (parts.length != 2) return false;
    final hh = int.tryParse(parts[0]);
    final mm = int.tryParse(parts[1]);
    if (hh == null || mm == null) return false;
    return hh >= 0 && hh <= 23 && mm >= 0 && mm <= 59;
  }

  void _listenManualSprayerTimes() {
    _subscriptions.add(
      deviceRepository.manualSprayerTimesStream().listen((data) {
        if (data.isEmpty) {
          manualSprayerTimes.value = [];
          return;
        }

        final List<TimeOfDay> times = [];
        final keys = data.keys.toList()
          ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
        for (final key in keys) {
          final parts = data[key]!.split(":");
          if (parts.length < 2) continue;
          final hour = int.tryParse(parts[0]);
          final minute = int.tryParse(parts[1]);
          if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) continue;
          times.add(TimeOfDay(hour: hour, minute: minute));
        }

        manualSprayerTimes.value = times;
      }),
    );
  }

  Future<void> setLampPWM(double percent) async {
    final snapped = _snapLampStep(percent);
    lampPWM.value = snapped.toDouble();
    await deviceRepository.setLampPWM(snapped);
  }

  Future<void> setManualSprayerDuration(int seconds) async {
    manualSprayerDuration.value = seconds;
    await deviceRepository.setManualSprayerDuration(seconds);
  }

  Future<void> saveManualSprayerTimes(List<TimeOfDay> list) async {
    final map = {
      for (int i = 0; i < list.length; i++)
        i.toString():
            "${list[i].hour.toString().padLeft(2, '0')}:${list[i].minute.toString().padLeft(2, '0')}"
    };
    await deviceRepository.setManualSprayerTimes(map);
  }

  void dispose() {
    _clockTimer?.cancel();
    _sprayerTimer?.cancel();
    _autoLightTimer?.cancel();
    autoLightPhaseInfo.dispose();
    plantAgeDays.dispose();
    darkPhaseDay.dispose();
    lightPhaseDay.dispose();
    currentPlantPhase.dispose();
    nextSprayerCountdownInfo.dispose();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
  }
}
