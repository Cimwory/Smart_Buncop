import 'package:flutter/material.dart';

/// Simple data object used by the form on `AddPlantPage`.
///
/// The page is responsible only for rendering widgets and reacting to user
/// interaction. Any conversion between the form fields and the shape that
/// The map structure the backend expects is handled here in the controller.
class PlantFormData {
  String name;
  bool auto;
  double pwm;
  double tempMin;
  double tempMax;
  int wateringDuration;
  int darkDays;
  int lightDays;
  String cycleStartPhase;
  DateTime cycleStartDate;
  TimeOfDay lightStartTime;
  TimeOfDay lightEndTime;
  List<TimeOfDay> wateringTimes;

  PlantFormData({
    this.name = '',
    this.auto = true,
    this.pwm = 60,
    this.tempMin = 22,
    this.tempMax = 28,
    this.wateringDuration = 10,
    this.darkDays = 7,
    this.lightDays = 7,
    this.cycleStartPhase = 'dark',
    DateTime? cycleStartDate,
    TimeOfDay? lightStartTime,
    TimeOfDay? lightEndTime,
    List<TimeOfDay>? wateringTimes,
  })  : cycleStartDate = DateTime(
          (cycleStartDate ?? DateTime.now()).year,
          (cycleStartDate ?? DateTime.now()).month,
          (cycleStartDate ?? DateTime.now()).day,
        ),
        lightStartTime = lightStartTime ?? const TimeOfDay(hour: 6, minute: 0),
        lightEndTime = lightEndTime ?? const TimeOfDay(hour: 17, minute: 0),
        wateringTimes = wateringTimes ?? [const TimeOfDay(hour: 8, minute: 0)];

  int _normalizePwm(double value) {
    if (value <= 0) return 0;
    final step = (value / 10).round() * 10;
    return step.clamp(0, 100);
  }

  /// Build the map structure expected by the backend.
  Map<String, dynamic> toMap() {
    final cycleDate =
        "${cycleStartDate.year.toString().padLeft(4, '0')}-"
        "${cycleStartDate.month.toString().padLeft(2, '0')}-"
        "${cycleStartDate.day.toString().padLeft(2, '0')}";

    return {
      "name": name,
      "auto": auto,
      "light_pwm": _normalizePwm(pwm),
      "par_target": 200,
      "light_cycle": {
        "phase_order": ["dark", "light"],
        "dark_days": darkDays,
        "light_days": lightDays,
        "start_phase": cycleStartPhase == 'light' ? 'light' : 'dark',
        "start_date": cycleDate,
      },
      "lighting": {
        "start_date": cycleDate,
        "start_time":
            "${lightStartTime.hour.toString().padLeft(2, '0')}:${lightStartTime.minute.toString().padLeft(2, '0')}",
        "end_time":
            "${lightEndTime.hour.toString().padLeft(2, '0')}:${lightEndTime.minute.toString().padLeft(2, '0')}",
      },
      "watering": {
        "times": wateringTimes
            .map((t) =>
                "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}")
            .toList(),
        "duration": wateringDuration,
      },
      "temp_optimal": {"min": tempMin, "max": tempMax},
    };
  }

  /// Create a [PlantFormData] instance from the raw data stored in the
  /// database. The page can call this in `initState` and then bind the
  /// resulting values to controllers or local state.
  factory PlantFormData.fromMap(Map<String, dynamic> data) {
    final result = PlantFormData();
    result.name = data['name'] ?? '';
    result.auto = (data['auto'] as bool?) ?? true;
    final rawPwm = (data['light_pwm'] as num?)?.toDouble() ?? 60;
    final snappedPwm = rawPwm <= 0
        ? 0
        : ((rawPwm / 10).round() * 10).clamp(0, 100);
    result.pwm = snappedPwm.toDouble();

    final temp = data['temp_optimal'];
    if (temp != null) {
      result.tempMin = (temp['min'] as num).toDouble();
      result.tempMax = (temp['max'] as num).toDouble();
    }

    final watering = data['watering'];
    if (watering != null) {
      result.wateringDuration = (watering['duration'] as int?) ?? 10;
      final times = watering['times'];
      if (times is List) {
        final parsed = <TimeOfDay>[];
        for (final e in times) {
          final parts = e.toString().split(":");
          if (parts.length < 2) continue;
          final hour = int.tryParse(parts[0]);
          final minute = int.tryParse(parts[1]);
          if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) continue;
          parsed.add(TimeOfDay(hour: hour, minute: minute));
        }
        if (parsed.isNotEmpty) {
          result.wateringTimes = parsed;
        }
      }
    }

    final lightCycleRaw = data['light_cycle'];
    if (lightCycleRaw is Map) {
      final lightCycle = Map<String, dynamic>.from(lightCycleRaw);
      final darkDays = (lightCycle['dark_days'] as num?)?.toInt() ?? 7;
      final lightDays = (lightCycle['light_days'] as num?)?.toInt() ?? 7;

      result.darkDays = darkDays < 1 ? 1 : darkDays;
      result.lightDays = lightDays < 1 ? 1 : lightDays;
      result.cycleStartPhase =
          (lightCycle['start_phase']?.toString().toLowerCase() == 'light')
              ? 'light'
              : 'dark';

      final startDateRaw = lightCycle['start_date']?.toString() ?? '';
      final parsedDate = DateTime.tryParse(startDateRaw);
      if (parsedDate != null) {
        result.cycleStartDate =
            DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
      }
    }

    final lightingRaw = data['lighting'];
    if (lightingRaw is Map) {
      final lighting = Map<String, dynamic>.from(lightingRaw);
      final startTimeRaw = lighting['start_time']?.toString() ?? '';
      final endTimeRaw = lighting['end_time']?.toString() ?? '';
      final startParts = startTimeRaw.split(':');
      final endParts = endTimeRaw.split(':');

      if (startParts.length >= 2) {
        final hour = int.tryParse(startParts[0]) ?? 6;
        final minute = int.tryParse(startParts[1]) ?? 0;
        result.lightStartTime = TimeOfDay(
          hour: hour.clamp(0, 23),
          minute: minute.clamp(0, 59),
        );
      }
      if (endParts.length >= 2) {
        final hour = int.tryParse(endParts[0]) ?? 17;
        final minute = int.tryParse(endParts[1]) ?? 0;
        result.lightEndTime = TimeOfDay(
          hour: hour.clamp(0, 23),
          minute: minute.clamp(0, 59),
        );
      }
    }

    return result;
  }
}

class PlantController {
  /// Helper to quickly build a plant map.  UI code should prefer [PlantFormData]
  /// and call `toMap` on it instead of invoking this directly.
  Map<String, dynamic> buildPlant({
    required String name,
    required bool auto,
    required double pwm,
    required double tempMin,
    required double tempMax,
    required List<String> wateringTimes,
    required int wateringDuration,
    int darkDays = 7,
    int lightDays = 7,
    String cycleStartPhase = 'dark',
    DateTime? cycleStartDate,
    TimeOfDay? lightStartTime,
    TimeOfDay? lightEndTime,
  }) {
    final snappedPwm = pwm <= 0 ? 0 : ((pwm / 10).round() * 10).clamp(0, 100);
    final selectedDate = cycleStartDate ?? DateTime.now();
    final cycleDate =
        "${selectedDate.year.toString().padLeft(4, '0')}-"
        "${selectedDate.month.toString().padLeft(2, '0')}-"
        "${selectedDate.day.toString().padLeft(2, '0')}";

    return {
      "name": name,
      "auto": auto,
      "light_pwm": snappedPwm,
      "par_target": 200,
      "light_cycle": {
        "phase_order": ["dark", "light"],
        "dark_days": darkDays < 1 ? 1 : darkDays,
        "light_days": lightDays < 1 ? 1 : lightDays,
        "start_phase": cycleStartPhase == 'light' ? 'light' : 'dark',
        "start_date": cycleDate,
      },
      "lighting": {
        "start_date": cycleDate,
        "start_time":
            "${(lightStartTime ?? const TimeOfDay(hour: 6, minute: 0)).hour.toString().padLeft(2, '0')}:${(lightStartTime ?? const TimeOfDay(hour: 6, minute: 0)).minute.toString().padLeft(2, '0')}",
        "end_time":
            "${(lightEndTime ?? const TimeOfDay(hour: 17, minute: 0)).hour.toString().padLeft(2, '0')}:${(lightEndTime ?? const TimeOfDay(hour: 17, minute: 0)).minute.toString().padLeft(2, '0')}",
      },
      "watering": {
        "times": wateringTimes,
        "duration": wateringDuration,
      },
      "temp_optimal": {"min": tempMin, "max": tempMax}
    };
  }
}
