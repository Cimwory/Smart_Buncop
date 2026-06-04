import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../services/app_session_service.dart';
import '../widgets/portal_scaffold.dart';

class TemperatureLogPage extends StatefulWidget {
  const TemperatureLogPage({super.key});

  @override
  State<TemperatureLogPage> createState() => _TemperatureLogPageState();
}

class _TemperatureLogPageState extends State<TemperatureLogPage> {
  static const Map<String, String> _measurementLabels = {
    'all': 'Semua Measurement',
    'incubator_sensor': 'Incubator',
    'monitoring_sensor': 'Monitoring Umum',
    'monitoring_atc_irigasi_rkk': 'ATC Irigasi RKK',
    'monitoring_atc_irigasi_rkb': 'ATC Irigasi RKB',
    'monitoring_atc_enviro': 'ATC Enviro',
    'monitoring_atc_hidroponik': 'ATC Smart Hidroponik',
  };

  static const Map<String, String> _fieldLabels = {
    'temperature': 'Temperature',
    'humidity': 'Humidity',
    'soil_moisture': 'Soil Moisture',
    'nh3': 'NH3',
    'ch4': 'CH4',
    'pH': 'pH',
    'tds': 'TDS',
    'weight_g': 'Weight',
    'target_weight_g': 'Target Weight',
  };

  final List<_SensorCatalogEntry> _catalog = <_SensorCatalogEntry>[
    if (AppConfig.inkubatorDeviceId.trim().isNotEmpty)
      _SensorCatalogEntry(
        label: 'Inkubator',
        deviceId: AppConfig.inkubatorDeviceId.trim(),
        measurement: 'incubator_sensor',
        fields: const ['temperature', 'humidity'],
      ),
    const _SensorCatalogEntry(
      label: 'BC1 Screen House',
      deviceId: 'bc1_screenhouse',
      measurement: 'monitoring_sensor',
      fields: ['temperature', 'humidity'],
    ),
    const _SensorCatalogEntry(
      label: 'BC2 Hidroponik',
      deviceId: 'bc2_hidroponik',
      measurement: 'monitoring_sensor',
      fields: ['temperature', 'humidity'],
    ),
    const _SensorCatalogEntry(
      label: 'BC2 Anggrek 1',
      deviceId: 'bc2_rumah_kaca_anggrek_1',
      measurement: 'monitoring_sensor',
      fields: ['temperature', 'humidity'],
    ),
    const _SensorCatalogEntry(
      label: 'BC2 Anggrek 2',
      deviceId: 'bc2_rumah_kaca_anggrek_2',
      measurement: 'monitoring_sensor',
      fields: ['temperature', 'humidity'],
    ),
    const _SensorCatalogEntry(
      label: 'BC2 Screen House 1',
      deviceId: 'bc2_screen_house_1',
      measurement: 'monitoring_sensor',
      fields: ['temperature', 'humidity'],
    ),
    const _SensorCatalogEntry(
      label: 'BC2 Screen House 2',
      deviceId: 'bc2_screen_house_2',
      measurement: 'monitoring_sensor',
      fields: ['temperature', 'humidity'],
    ),
    const _SensorCatalogEntry(
      label: 'ATC Irigasi RKK',
      deviceId: 'atc_irigasi_rkk',
      measurement: 'monitoring_atc_irigasi_rkk',
      fields: ['temperature', 'humidity', 'soil_moisture'],
    ),
    const _SensorCatalogEntry(
      label: 'ATC Irigasi RKB',
      deviceId: 'atc_irigasi_rkb',
      measurement: 'monitoring_atc_irigasi_rkb',
      fields: ['temperature', 'humidity', 'soil_moisture'],
    ),
    const _SensorCatalogEntry(
      label: 'ATC Enviro',
      deviceId: 'atc_enviro',
      measurement: 'monitoring_atc_enviro',
      fields: ['nh3', 'ch4'],
    ),
    const _SensorCatalogEntry(
      label: 'ATC Smart Hidroponik',
      deviceId: 'atc_smart_hidroponik',
      measurement: 'monitoring_atc_hidroponik',
      fields: ['pH', 'tds'],
    ),
  ];

  final Set<String> _selectedDeviceIds = <String>{};
  final Set<String> _selectedFields = <String>{'temperature', 'humidity'};

  String _selectedMeasurement = 'all';
  String _selectedRange = '-1d';
  String _selectedWindow = '1m';
  bool _loading = true;
  String? _error;
  DateTime? _lastUpdatedAt;
  Timer? _refreshTimer;
  List<_HistorySeriesCard> _cards = const <_HistorySeriesCard>[];
  String _queryMode = 'belum ada';
  String _requestTargetSummary = '-';
  String _responseDebug = '-';
  String _lastEndpoint = '-';

  List<_SensorCatalogEntry> get _visibleDevices {
    if (_selectedMeasurement == 'all') return _catalog;
    return _catalog.where((item) => item.measurement == _selectedMeasurement).toList();
  }

  List<String> get _visibleFields {
    final set = <String>{};
    for (final item in _visibleDevices) {
      set.addAll(item.fields);
    }
    final list = set.toList()..sort();
    return list;
  }

  @override
  void initState() {
    super.initState();
    _selectedDeviceIds.addAll(_catalog.map((item) => item.deviceId));
    _normalizeSelection();
    _loadHistory();
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _loadHistory(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _normalizeSelection() {
    final visibleDeviceIds = _visibleDevices.map((item) => item.deviceId).toSet();
    _selectedDeviceIds.removeWhere((id) => !visibleDeviceIds.contains(id));
    if (_selectedDeviceIds.isEmpty) {
      _selectedDeviceIds.addAll(visibleDeviceIds);
    }

    final visibleFields = _visibleFields.toSet();
    _selectedFields.removeWhere((field) => !visibleFields.contains(field));
    if (_selectedFields.isEmpty && visibleFields.isNotEmpty) {
      if (visibleFields.contains('temperature')) _selectedFields.add('temperature');
      if (visibleFields.contains('humidity')) _selectedFields.add('humidity');
      if (_selectedFields.isEmpty) {
        _selectedFields.add(visibleFields.first);
      }
    }
  }

  Future<void> _loadHistory({bool silent = false}) async {
    final apiBase = AppConfig.apiBase.trim();
    final hasToken = (AppSessionService.token ?? '').trim().isNotEmpty;
    if (apiBase.isEmpty || !hasToken) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = apiBase.isEmpty
            ? 'BUNCOP_API_BASE belum diset.'
            : 'Sesi login sudah habis. Silakan login ulang.';
        _responseDebug = apiBase.isEmpty
            ? 'Config API kosong'
            : 'Token login tidak tersedia';
      });
      return;
    }

    final selectedEntries = _visibleDevices
        .where((item) => _selectedDeviceIds.contains(item.deviceId))
        .toList();

    final queries = selectedEntries
        .map((entry) {
          final fields = entry.fields.where(_selectedFields.contains).toList();
          if (fields.isEmpty) return null;
          return <String, dynamic>{
            'label': entry.label,
            'device_id': entry.deviceId,
            'measurement': entry.measurement,
            'fields': fields,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    if (queries.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _cards = const <_HistorySeriesCard>[];
        _error = 'Pilih minimal satu device dan satu field.';
        _queryMode = 'tidak ada query';
        _requestTargetSummary = '-';
        _responseDebug = 'Query kosong';
      });
      return;
    }

    final targetSummary = selectedEntries
        .map((entry) => '${entry.label} (${entry.deviceId})')
        .join(', ');

    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _requestTargetSummary = targetSummary;
      });
    }

    try {
      final uris = _sensorHistoryUris(apiBase);
      final cards = await _loadHistoryCards(
        uris: uris,
        selectedEntries: selectedEntries,
      );

      if (!mounted) return;
      setState(() {
        _cards = cards;
        _loading = false;
        _error = cards.isEmpty ? 'Belum ada data histori untuk filter yang dipilih.' : null;
        _lastUpdatedAt = DateTime.now();
        _queryMode = 'per-device sync';
        _responseDebug =
            'endpoint=$_lastEndpoint | devices=${selectedEntries.length} | cards=${cards.length}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _cards = const <_HistorySeriesCard>[];
        _error = e.toString();
        _lastUpdatedAt = DateTime.now();
        _queryMode = 'gagal';
        _responseDebug = 'Exception: $e | endpoint=$_lastEndpoint';
      });
    }
  }

  Future<List<_HistorySeriesCard>> _loadHistoryCards({
    required List<Uri> uris,
    required List<_SensorCatalogEntry> selectedEntries,
  }) async {
    final cards = <_HistorySeriesCard>[];

    for (final entry in selectedEntries) {
      final requestedFields = entry.fields.where(_selectedFields.contains).toList();
      if (requestedFields.isEmpty) continue;

      List<Map<String, dynamic>> points = <Map<String, dynamic>>[];
      final supportsBaseHistoryOnly = requestedFields.every(
        (field) => field == 'temperature' || field == 'humidity',
      );

      if (supportsBaseHistoryOnly) {
        points = await _fetchHistoryRows(
          uris: uris,
          entry: entry,
          requestedFields: const <String>[],
        );
      }

      if (points.isEmpty) {
        points = await _fetchHistoryRows(
          uris: uris,
          entry: entry,
          requestedFields: requestedFields,
        );
      }

      if (points.isEmpty) continue;
      for (final field in requestedFields) {
        final seriesPoints = <_HistorySeriesPoint>[];
        for (final row in points) {
          final at = _parseHistoryDateTime(row);
          if (at == null) continue;
          final value = (row[field] as num?)?.toDouble();
          seriesPoints.add(_HistorySeriesPoint(at: at, value: value));
        }

        if (seriesPoints.every((point) => point.value == null)) continue;

        cards.add(
          _HistorySeriesCard(
            label: entry.label,
            deviceId: entry.deviceId,
            measurement: entry.measurement,
            field: field,
            points: seriesPoints,
          ),
        );
      }
    }

    cards.sort((a, b) {
      final byLabel = a.label.compareTo(b.label);
      if (byLabel != 0) return byLabel;
      return a.field.compareTo(b.field);
    });

    return cards;
  }

  Future<List<Map<String, dynamic>>> _fetchHistoryRows({
    required List<Uri> uris,
    required _SensorCatalogEntry entry,
    required List<String> requestedFields,
  }) async {
    http.Response? response;

    for (final uri in uris) {
      try {
        _lastEndpoint = uri.toString();
        final queryParameters = <String, String>{
          'device_id': entry.deviceId,
          'measurement': entry.measurement,
          'range': _selectedRange,
          'window': _selectedWindow,
        };
        if (requestedFields.isNotEmpty) {
          queryParameters['fields'] = requestedFields.join(',');
        }

        final current = await http.get(
          uri.replace(queryParameters: queryParameters),
          headers: AppSessionService.buildAuthHeaders(json: false),
        ).timeout(const Duration(seconds: 15));

        if (current.statusCode >= 200 && current.statusCode < 300) {
          response = current;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    if (response == null) return const <Map<String, dynamic>>[];

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const <Map<String, dynamic>>[];
    final rawData = decoded['data'];
    if (rawData is! List) return const <Map<String, dynamic>>[];

    return rawData.whereType<Map<String, dynamic>>().toList();
  }

  List<Uri> _sensorHistoryUris(String apiBase) {
    final apiV1Base = AppConfig.normalizeApiV1Base(apiBase);
    return <Uri>[
      if (apiV1Base.isNotEmpty) Uri.parse('$apiV1Base/incubator/sync/sensor-history'),
    ];
  }

  DateTime? _parseHistoryDateTime(Map<String, dynamic> row) {
    final rawTime = row['time']?.toString() ?? '';
    final parsedTime = DateTime.tryParse(rawTime)?.toLocal();
    if (parsedTime != null) return parsedTime;

    final rawTimestamp = row['timestamp'];
    if (rawTimestamp is num) {
      return DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt() * 1000).toLocal();
    }

    return null;
  }

  String _fmtDateTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return PortalScaffold(
      badge: 'SENSOR LOG',
      title: 'Log Suhu',
      subtitle: 'Histori chart multi device langsung dari InfluxDB',
      actions: [
        PortalActionButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onTap: _loadHistory,
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
          _FilterPanel(
            measurementLabels: _measurementLabels,
            selectedMeasurement: _selectedMeasurement,
            onMeasurementChanged: (value) {
              setState(() {
                _selectedMeasurement = value;
                _normalizeSelection();
              });
              _loadHistory();
            },
            rangeValue: _selectedRange,
            onRangeChanged: (value) {
              setState(() => _selectedRange = value);
              _loadHistory();
            },
            windowValue: _selectedWindow,
            onWindowChanged: (value) {
              setState(() => _selectedWindow = value);
              _loadHistory();
            },
            devices: _visibleDevices,
            selectedDeviceIds: _selectedDeviceIds,
            onToggleDevice: (deviceId) {
              setState(() {
                if (_selectedDeviceIds.contains(deviceId)) {
                  _selectedDeviceIds.remove(deviceId);
                } else {
                  _selectedDeviceIds.add(deviceId);
                }
                _normalizeSelection();
              });
              _loadHistory();
            },
            fieldLabels: _fieldLabels,
            visibleFields: _visibleFields,
            selectedFields: _selectedFields,
            onToggleField: (field) {
              setState(() {
                if (_selectedFields.contains(field)) {
                  _selectedFields.remove(field);
                } else {
                  _selectedFields.add(field);
                }
                _normalizeSelection();
              });
              _loadHistory();
            },
            summary:
                'Measurement: ${_measurementLabels[_selectedMeasurement]} | Device aktif: ${_selectedDeviceIds.length} | Field aktif: ${_selectedFields.length} | Range: $_selectedRange | Window: $_selectedWindow | Mode: $_queryMode | Last refresh: ${_fmtDateTime(_lastUpdatedAt ?? DateTime.now())}',
            requestTargetSummary: _requestTargetSummary,
            responseDebug: _responseDebug,
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text(
              _error!,
              style: const TextStyle(color: Color(0xFFFFCDD2)),
            )
          else if (_cards.isEmpty)
            const Text(
              'Belum ada data chart untuk filter yang dipilih.',
              style: TextStyle(color: Color(0xFFC7DFD2)),
            )
          else
            ..._cards.map((card) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _HistoryChartCard(
                    card: card,
                    color: _colorForField(card.field),
                    fieldLabel: _fieldLabels[card.field] ?? card.field,
                  ),
                )),
        ],
      ),
    );
  }

  Color _colorForField(String field) {
    switch (field) {
      case 'temperature':
        return const Color(0xFFFF8A65);
      case 'humidity':
        return const Color(0xFF4FC3F7);
      case 'soil_moisture':
        return const Color(0xFF81C784);
      case 'nh3':
        return const Color(0xFFFFD54F);
      case 'ch4':
        return const Color(0xFFBA68C8);
      case 'pH':
        return const Color(0xFF64B5F6);
      case 'tds':
        return const Color(0xFFA1887F);
      default:
        return const Color(0xFF90CAF9);
    }
  }
}

class _FilterPanel extends StatelessWidget {
  final Map<String, String> measurementLabels;
  final String selectedMeasurement;
  final ValueChanged<String> onMeasurementChanged;
  final String rangeValue;
  final ValueChanged<String> onRangeChanged;
  final String windowValue;
  final ValueChanged<String> onWindowChanged;
  final List<_SensorCatalogEntry> devices;
  final Set<String> selectedDeviceIds;
  final ValueChanged<String> onToggleDevice;
  final Map<String, String> fieldLabels;
  final List<String> visibleFields;
  final Set<String> selectedFields;
  final ValueChanged<String> onToggleField;
  final String summary;
  final String requestTargetSummary;
  final String responseDebug;

  const _FilterPanel({
    required this.measurementLabels,
    required this.selectedMeasurement,
    required this.onMeasurementChanged,
    required this.rangeValue,
    required this.onRangeChanged,
    required this.windowValue,
    required this.onWindowChanged,
    required this.devices,
    required this.selectedDeviceIds,
    required this.onToggleDevice,
    required this.fieldLabels,
    required this.visibleFields,
    required this.selectedFields,
    required this.onToggleField,
    required this.summary,
    required this.requestTargetSummary,
    required this.responseDebug,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x1F2D6B44),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x5568A57F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: measurementLabels.entries.map((entry) {
              return ChoiceChip(
                label: Text(entry.value),
                selected: selectedMeasurement == entry.key,
                onSelected: (_) => onMeasurementChanged(entry.key),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: rangeValue,
                  decoration: const InputDecoration(
                    labelText: 'Range',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: '-1h', child: Text('1 Jam')),
                    DropdownMenuItem(value: '-6h', child: Text('6 Jam')),
                    DropdownMenuItem(value: '-1d', child: Text('1 Hari')),
                    DropdownMenuItem(value: '-7d', child: Text('7 Hari')),
                    DropdownMenuItem(value: '-30d', child: Text('30 Hari')),
                  ],
                  onChanged: (value) {
                    if (value != null) onRangeChanged(value);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: windowValue,
                  decoration: const InputDecoration(
                    labelText: 'Window',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: '10s', child: Text('10 Detik')),
                    DropdownMenuItem(value: '30s', child: Text('30 Detik')),
                    DropdownMenuItem(value: '1m', child: Text('1 Menit')),
                    DropdownMenuItem(value: '5m', child: Text('5 Menit')),
                    DropdownMenuItem(value: '15m', child: Text('15 Menit')),
                    DropdownMenuItem(value: '30m', child: Text('30 Menit')),
                    DropdownMenuItem(value: '1h', child: Text('1 Jam')),
                  ],
                  onChanged: (value) {
                    if (value != null) onWindowChanged(value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Device',
            style: TextStyle(
              color: Color(0xFFE8F5E9),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: devices.map((device) {
              return FilterChip(
                label: Text(device.label),
                selected: selectedDeviceIds.contains(device.deviceId),
                onSelected: (_) => onToggleDevice(device.deviceId),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          const Text(
            'Field',
            style: TextStyle(
              color: Color(0xFFE8F5E9),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: visibleFields.map((field) {
              return FilterChip(
                label: Text(fieldLabels[field] ?? field),
                selected: selectedFields.contains(field),
                onSelected: (_) => onToggleField(field),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Text(
            summary,
            style: const TextStyle(
              color: Color(0xFFBBD8C6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Target query: $requestTargetSummary',
            style: const TextStyle(
              color: Color(0xFFCFE7D5),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            'Response debug: $responseDebug',
            style: const TextStyle(
              color: Color(0xFFB8DCC4),
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryChartCard extends StatelessWidget {
  final _HistorySeriesCard card;
  final Color color;
  final String fieldLabel;

  const _HistoryChartCard({
    required this.card,
    required this.color,
    required this.fieldLabel,
  });

  @override
  Widget build(BuildContext context) {
    final chartPoints = <FlSpot>[];
    final validValues = <double>[];

    for (final point in card.points) {
      final at = point.at;
      if (point.value == null || at == null) continue;
      final minuteOfDay = at.hour * 60 + at.minute + (at.second / 60.0);
      chartPoints.add(FlSpot(minuteOfDay, point.value!));
      validValues.add(point.value!);
    }

    chartPoints.sort((a, b) => a.x.compareTo(b.x));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x1F2D6B44),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x5568A57F)),
      ),
      child: chartPoints.isEmpty
          ? Text(
              'Belum ada data $fieldLabel untuk ${card.label}.',
              style: const TextStyle(color: Color(0xFFC7DFD2)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${card.label} • $fieldLabel',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Measurement: ${card.measurement} | Device: ${card.deviceId}',
                  style: const TextStyle(
                    color: Color(0xFFC7DFD2),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Data: ${chartPoints.length} titik | Latest: ${validValues.last.toStringAsFixed(1)} | Min: ${validValues.reduce(math.min).toStringAsFixed(1)} | Max: ${validValues.reduce(math.max).toStringAsFixed(1)}',
                  style: const TextStyle(
                    color: Color(0xFFC7DFD2),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 220,
                  child: LineChart(
                    LineChartData(
                      minX: chartPoints.first.x,
                      maxX: _expandedMaxX(chartPoints.first.x, chartPoints.last.x),
                      minY: _expandedMinY(validValues),
                      maxY: _expandedMaxY(validValues),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        verticalInterval: _xInterval(chartPoints.first.x, chartPoints.last.x),
                        horizontalInterval: _yInterval(validValues),
                        getDrawingHorizontalLine: (_) =>
                            const FlLine(color: Colors.white12, strokeWidth: 1),
                        getDrawingVerticalLine: (_) =>
                            const FlLine(color: Colors.white12, strokeWidth: 1),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.white24),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 36,
                            interval: _yInterval(validValues),
                            getTitlesWidget: (value, _) => Text(
                              value.toStringAsFixed(0),
                              style: const TextStyle(
                                color: Color(0xFFBBD8C6),
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            interval: _xInterval(chartPoints.first.x, chartPoints.last.x),
                            getTitlesWidget: _bottomTitle,
                          ),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: chartPoints,
                          isCurved: false,
                          color: color,
                          barWidth: 2.4,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  double _expandedMaxX(double minX, double maxX) {
    final span = maxX - minX;
    if (span < 15) return minX + 15;
    return maxX;
  }

  double _expandedMinY(List<double> values) {
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final pad = math.max(0.5, (maxValue - minValue) * 0.25);
    return (minValue - pad).floorToDouble();
  }

  double _expandedMaxY(List<double> values) {
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final pad = math.max(0.5, (maxValue - minValue) * 0.25);
    return (maxValue + pad).ceilToDouble();
  }

  double _yInterval(List<double> values) {
    final range = _expandedMaxY(values) - _expandedMinY(values);
    if (range <= 4) return 1;
    if (range <= 8) return 2;
    return 5;
  }

  double _xInterval(double minX, double maxX) {
    final span = maxX - minX;
    if (span <= 15) return 5;
    if (span <= 60) return 15;
    if (span <= 180) return 30;
    return 60;
  }

  Widget _bottomTitle(double value, TitleMeta meta) {
    final totalMinutes = value.round();
    final hour = (totalMinutes ~/ 60).toString().padLeft(2, '0');
    final minute = (totalMinutes % 60).toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        '$hour:$minute',
        style: const TextStyle(
          color: Color(0xFFBBD8C6),
          fontSize: 10,
        ),
      ),
    );
  }
}

class _SensorCatalogEntry {
  final String label;
  final String deviceId;
  final String measurement;
  final List<String> fields;

  const _SensorCatalogEntry({
    required this.label,
    required this.deviceId,
    required this.measurement,
    required this.fields,
  });
}

class _HistorySeriesCard {
  final String label;
  final String deviceId;
  final String measurement;
  final String field;
  final List<_HistorySeriesPoint> points;

  const _HistorySeriesCard({
    required this.label,
    required this.deviceId,
    required this.measurement,
    required this.field,
    required this.points,
  });

  factory _HistorySeriesCard.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    return _HistorySeriesCard(
      label: json['label']?.toString() ?? json['device_id']?.toString() ?? '-',
      deviceId: json['device_id']?.toString() ?? '-',
      measurement: json['measurement']?.toString() ?? '-',
      field: json['field']?.toString() ?? '-',
      points: rawPoints is List
          ? rawPoints
              .whereType<Map<String, dynamic>>()
              .map(_HistorySeriesPoint.fromJson)
              .where((point) => point.at != null)
              .cast<_HistorySeriesPoint>()
              .toList()
          : const <_HistorySeriesPoint>[],
    );
  }
}

class _HistorySeriesPoint {
  final DateTime? at;
  final double? value;

  const _HistorySeriesPoint({
    required this.at,
    required this.value,
  });

  factory _HistorySeriesPoint.fromJson(Map<String, dynamic> json) {
    final rawTime = json['time']?.toString() ?? '';
    final parsedTime = DateTime.tryParse(rawTime)?.toLocal();
    final rawTimestamp = json['timestamp'];
    final timestampTime = rawTimestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt() * 1000).toLocal()
        : null;

    return _HistorySeriesPoint(
      at: parsedTime ?? timestampTime,
      value: (json['value'] as num?)?.toDouble(),
    );
  }
}
