import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../services/app_session_service.dart';
import '../widgets/portal_scaffold.dart';

class ActivityLogPage extends StatefulWidget {
  const ActivityLogPage({super.key});

  @override
  State<ActivityLogPage> createState() => _ActivityLogPageState();
}

class _ActivityLogPageState extends State<ActivityLogPage> {
  static String get _baseUrl => AppConfig.requireApiBase();

  final _searchCtrl = TextEditingController();

  DateTime? _userDateTimeFrom;
  DateTime? _userDateTimeTo;

  Timer? _autoRefreshTimer;
  DateTime? _lastRefreshedAt;
  bool _isReloading = false;
  bool _loading = false;
  String? _error;
  List<_LogItem> _logs = const <_LogItem>[];

  @override
  void initState() {
    super.initState();
    _resetToTodayRange();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_hasSelectedRange) {
        _reload(silent: true);
      }
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _hasSelectedRange => _userDateTimeFrom != null || _userDateTimeTo != null;

  void _resetToTodayRange() {
    final now = DateTime.now();
    _userDateTimeFrom = DateTime(now.year, now.month, now.day, 0, 0, 0);
    _userDateTimeTo = DateTime(now.year, now.month, now.day, 23, 59, 59);
  }

  String _formatLocalQueryDateTime(DateTime value) {
    final local = value.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  Future<List<_LogItem>> _fetchLogs() async {
    if (!_hasSelectedRange) {
      return const <_LogItem>[];
    }

    final queryParameters = <String, String>{
      'limit': '300',
    };
    if (_userDateTimeFrom != null) {
      queryParameters['datetime_from'] =
          _formatLocalQueryDateTime(_userDateTimeFrom!);
    }
    if (_userDateTimeTo != null) {
      queryParameters['datetime_to'] = _formatLocalQueryDateTime(_userDateTimeTo!);
    }

    final uri = Uri.parse('$_baseUrl/activity-logs').replace(
      queryParameters: queryParameters,
    );
    final response = await http.get(
      uri,
      headers: AppSessionService.buildAuthHeaders(json: false),
    );

    if (response.statusCode >= 400) {
      throw Exception('Gagal memuat log (${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return [];
    final data = decoded['data'];
    if (data is! List) return [];

    final result = data.map<_LogItem>((item) {
      final map = item is Map<String, dynamic> ? item : <String, dynamic>{};
      return _LogItem.fromJson(map);
    }).toList();

    result.sort((a, b) => b.performedAtRaw.compareTo(a.performedAtRaw));
    return result;
  }

  Future<void> _reload({bool silent = false}) async {
    if (_isReloading) return;
    if (!_hasSelectedRange) {
      if (!mounted) return;
      setState(() {
        _logs = const <_LogItem>[];
        _error = null;
        _loading = false;
      });
      return;
    }

    _isReloading = true;
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final logs = await _fetchLogs();
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _loading = false;
        _error = null;
        _lastRefreshedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
        _lastRefreshedAt = DateTime.now();
      });
    } finally {
      _isReloading = false;
    }
  }

  bool _matchesSearch(_LogItem log, String keyword) {
    if (keyword.isEmpty) return true;
    final haystack = [
      log.userName,
      log.deviceId,
      log.description,
      log.module,
      log.action,
    ].join(' ').toLowerCase();
    return haystack.contains(keyword);
  }

  List<_LogItem> _filteredUserLogs(List<_LogItem> allLogs) {
    final keyword = _searchCtrl.text.trim().toLowerCase();

    return allLogs
        .where((log) => _matchesSearch(log, keyword))
        .toList()
      ..sort((a, b) => b.performedAtRaw.compareTo(a.performedAtRaw));
  }

  @override
  Widget build(BuildContext context) {
    return PortalScaffold(
      badge: 'ADMIN ROLE',
      title: 'User Activity Log',
      subtitle: 'Realtime records from backend activity_logs',
      actions: [
        PortalActionButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onTap: () => _reload(),
        ),
        PortalActionButton(
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onTap: () => Navigator.pop(context),
        ),
      ],
      child: Builder(
        builder: (context) {
          final userLogs = _filteredUserLogs(_logs);
          return Column(
            children: [
              _filterPanel(),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                _errorState(_error!)
              else
                _logListPanel(userLogs),
            ],
          );
        },
      ),
    );
  }

  Widget _filterPanel() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x1F2D6B44),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x5568A57F)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                labelText: 'Cari nama/device',
                hintText: 'Masukkan nama lengkap atau device (boleh sebagian)',
              ),
              onSubmitted: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 340,
                  child: _filterCard(
                    title: 'Filter User Logs',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _dateTimeField(
                          title: 'Dari',
                          value: _userDateTimeFrom,
                          onTap: () async {
                            final picked = await _pickDateTime(_userDateTimeFrom);
                            if (picked == null) return;
                            setState(() => _userDateTimeFrom = picked);
                          },
                        ),
                        const SizedBox(height: 8),
                        _dateTimeField(
                          title: 'Sampai',
                          value: _userDateTimeTo,
                          onTap: () async {
                            final picked = await _pickDateTime(_userDateTimeTo);
                            if (picked == null) return;
                            setState(() => _userDateTimeTo = picked);
                          },
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _reload(),
                            icon: const Icon(Icons.search),
                            label: const Text('Apply User Logs'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _resetToTodayRange();
                                _error = null;
                              });
                              _reload();
                            },
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('Reset'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _hasSelectedRange
                  ? 'Auto refresh: 15 detik | Last refresh: ${_fmtDateTime(_lastRefreshedAt ?? DateTime.now())}'
                  : 'Menampilkan log hari ini 00:00-23:59. Pilih rentang lain lalu tekan Apply untuk mengambil data.',
              style: const TextStyle(
                color: Color(0xFFBBD8C6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x16326C4A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x557EB696)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFE4F3EA),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _dateTimeField({
    required String title,
    required DateTime? value,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.schedule, size: 18),
        label: Align(
          alignment: Alignment.centerLeft,
          child: Text('$title: ${value == null ? 'Belum dipilih' : _fmtDateTime(value)}'),
        ),
      ),
    );
  }

  Widget _logListPanel(List<_LogItem> logs) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x1F2D6B44),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x5568A57F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'User Logs (${logs.length} rows)',
            style: const TextStyle(
              color: Color(0xFFE8F5E9),
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 420,
            child: logs.isEmpty
                ? const Center(
                    child: Text(
                      'Belum ada user log pada filter saat ini.',
                      style: TextStyle(color: Color(0xFFC7DFD2)),
                    ),
                  )
                : ListView.separated(
                    itemCount: logs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _logCard(logs[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _logCard(_LogItem log) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x16326C4A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x557EB696)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            log.action,
            style: const TextStyle(
              color: Color(0xFFE8F5E9),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${log.userName} | ${log.module} | ${log.deviceId.isEmpty ? '-' : log.deviceId}',
            style: const TextStyle(
              color: Color(0xFFBBD8C6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            log.description,
            style: const TextStyle(
              color: Color(0xFFE8F5E9),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            log.performedAt,
            style: const TextStyle(
              color: Color(0xFF9FD0B0),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Future<DateTime?> _pickDateTime(DateTime? initial) async {
    final now = DateTime.now();
    final initialDate = initial ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial ?? now),
    );
    if (time == null || !mounted) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
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

  String _fmtDateOnly(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Widget _errorState(String message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Gagal memuat activity log.',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFFFFCDD2),
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          style: const TextStyle(color: Color(0xFFFFCDD2)),
        ),
      ],
    );
  }
}

class _LogItem {
  final String module;
  final String action;
  final String description;
  final String deviceId;
  final String performedAt;
  final DateTime performedAtRaw;
  final String userName;

  const _LogItem({
    required this.module,
    required this.action,
    required this.description,
    required this.deviceId,
    required this.performedAt,
    required this.performedAtRaw,
    required this.userName,
  });

  factory _LogItem.fromJson(Map<String, dynamic> json) {
    final rawTime = json['performed_at_local']?.toString() ??
        json['performed_at']?.toString() ??
        '';
    final timestampMs = json['performed_at_ts'];
    final parsedFromTimestamp = timestampMs is num
        ? DateTime.fromMillisecondsSinceEpoch(timestampMs.toInt())
        : null;
    final parsedTime =
        parsedFromTimestamp ?? DateTime.tryParse(json['performed_at']?.toString() ?? '');
    final timeLabel = rawTime.length >= 19
        ? rawTime.substring(0, 19).replaceFirst('T', ' ')
        : (parsedTime != null
            ? '${parsedTime.toLocal().year.toString().padLeft(4, '0')}-${parsedTime.toLocal().month.toString().padLeft(2, '0')}-${parsedTime.toLocal().day.toString().padLeft(2, '0')} ${parsedTime.toLocal().hour.toString().padLeft(2, '0')}:${parsedTime.toLocal().minute.toString().padLeft(2, '0')}:${parsedTime.toLocal().second.toString().padLeft(2, '0')}'
            : rawTime);
    final metadata = (json['metadata'] is Map<String, dynamic>)
        ? json['metadata'] as Map<String, dynamic>
        : <String, dynamic>{};

    return _LogItem(
      module: json['module']?.toString() ?? '-',
      action: json['action']?.toString() ?? '-',
      description: json['description']?.toString() ?? '-',
      deviceId: json['device_id']?.toString() ?? '',
      performedAt: timeLabel,
      performedAtRaw: parsedTime?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
      userName: json['user_name']?.toString() ??
          json['login_identifier']?.toString() ??
          'system',
    );
  }
}
