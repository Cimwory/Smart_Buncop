import 'package:flutter/material.dart';

import '../services/backend_control_api_service.dart';
import '../widgets/portal_scaffold.dart';

class BackendControlPage extends StatefulWidget {
  const BackendControlPage({super.key});

  @override
  State<BackendControlPage> createState() => _BackendControlPageState();
}

class _BackendControlPageState extends State<BackendControlPage> {
  final _service = BackendControlApiService();
  final _pinController = TextEditingController();
  final _pinConfirmationController = TextEditingController();
  final _unlockDurationController = TextEditingController(text: '30');

  IndoorFarmingAdminConfig? _config;
  bool _loading = true;
  bool _savingPin = false;
  bool _savingGrant = false;
  int? _revokingGrantId;
  int? _selectedUserId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _pinConfirmationController.dispose();
    _unlockDurationController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final config = await _service.fetchIndoorFarmingConfig();
      if (!mounted) return;
      setState(() {
        _config = config;
        _unlockDurationController.text =
            config.pinSetting.unlockDurationMinutes.toString();
        _selectedUserId = config.grantCandidates.isNotEmpty
            ? config.grantCandidates.first.id
            : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _savePin({bool disablePin = false}) async {
    if (_savingPin) return;
    final unlockDuration =
        int.tryParse(_unlockDurationController.text.trim()) ?? 30;

    setState(() => _savingPin = true);
    try {
      final message = await _service.saveIndoorFarmingPin(
        pin: _pinController.text,
        pinConfirmation: _pinConfirmationController.text,
        unlockDurationMinutes: unlockDuration,
        disablePin: disablePin,
      );
      _pinController.clear();
      _pinConfirmationController.clear();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() => _savingPin = false);
      }
    }
  }

  Future<void> _grantAccess() async {
    final userId = _selectedUserId;
    if (_savingGrant || userId == null) return;

    setState(() => _savingGrant = true);
    try {
      final message = await _service.createIndoorFarmingGrant(userId);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() => _savingGrant = false);
      }
    }
  }

  Future<void> _revokeAccess(IndoorFarmingAccessGrantItem grant) async {
    if (_revokingGrantId != null) return;

    setState(() => _revokingGrantId = grant.id);
    try {
      final message = await _service.revokeIndoorFarmingGrant(grant.id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() => _revokingGrantId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PortalScaffold(
      badge: 'BACKEND',
      title: 'Backend Control',
      subtitle: 'PIN indoor farming dan akses penuh tanpa PIN untuk user',
      actions: [
        PortalActionButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onTap: _load,
        ),
        PortalActionButton(
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onTap: () => Navigator.pop(context),
        ),
      ],
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorState()
          : _content(),
    );
  }

  Widget _errorState() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xB3123323),
        border: Border.all(color: const Color(0x66FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gagal memuat backend control.',
            style: TextStyle(
              color: Color(0xFFFFCDD2),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? '-',
            style: const TextStyle(color: Color(0xFFEAF8EF)),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    final config = _config!;
    final pinSetting = config.pinSetting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionCard(
          title: 'PIN Indoor Farming',
          subtitle:
              'Sama seperti dashboard web: atur PIN, durasi unlock, atau nonaktifkan PIN.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _tag(pinSetting.isEnabled ? 'PIN Aktif' : 'PIN Nonaktif'),
                  _tag('Unlock ${pinSetting.unlockDurationMinutes} menit'),
                  if (pinSetting.updatedByName != null)
                    _tag('Update ${pinSetting.updatedByName}'),
                ],
              ),
              const SizedBox(height: 14),
              _input(
                controller: _pinController,
                label: 'PIN Baru',
                hint: pinSetting.hasPin
                    ? 'Kosongkan jika tidak ganti PIN'
                    : '4 sampai 8 digit angka',
                obscure: true,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              _input(
                controller: _pinConfirmationController,
                label: 'Konfirmasi PIN',
                hint: 'Ulangi PIN',
                obscure: true,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              _input(
                controller: _unlockDurationController,
                label: 'Durasi Akses (menit)',
                hint: '1 - 1440',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _savingPin ? null : () => _savePin(),
                      icon: const Icon(Icons.save_rounded),
                      label: Text(_savingPin ? 'Menyimpan...' : 'Simpan PIN'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _savingPin
                          ? null
                          : () => _savePin(disablePin: true),
                      icon: const Icon(Icons.block_rounded),
                      label: const Text('Nonaktifkan PIN'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0x55FFFFFF)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'Akses Penuh Tanpa PIN',
          subtitle:
              'Berikan bypass PIN ke akun user tertentu, sama seperti halaman backend di web.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (config.grantCandidates.isEmpty)
                const Text(
                  'Belum ada kandidat user aktif untuk diberi akses.',
                  style: TextStyle(color: Color(0xFFD9F2DD)),
                )
              else ...[
                DropdownButtonFormField<int>(
                  value: _selectedUserId,
                  dropdownColor: const Color(0xFF123323),
                  style: const TextStyle(color: Color(0xFFEAF8EF)),
                  decoration: _inputDecoration('Pilih User'),
                  items: config.grantCandidates
                      .map(
                        (user) => DropdownMenuItem<int>(
                          value: user.id,
                          child: Text('${user.name} (${user.email})'),
                        ),
                      )
                      .toList(),
                  onChanged: _savingGrant
                      ? null
                      : (value) => setState(() => _selectedUserId = value),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _savingGrant ? null : _grantAccess,
                    icon: const Icon(Icons.verified_user_outlined),
                    label: Text(
                      _savingGrant ? 'Menyimpan...' : 'Berikan Akses Penuh',
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'Daftar Grant Aktif',
                style: TextStyle(
                  color: Color(0xFFF1F8E9),
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 10),
              if (config.accessGrants.isEmpty)
                const Text(
                  'Belum ada grant akses penuh indoor farming.',
                  style: TextStyle(color: Color(0xFFD9F2DD)),
                ),
              ...config.accessGrants.map(
                (grant) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: const Color(0x22184F2C),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        grant.userName,
                        style: const TextStyle(
                          color: Color(0xFFF1F8E9),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        grant.userEmail,
                        style: const TextStyle(color: Color(0xFFD9F2DD)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Granted by ${grant.grantedByName}',
                        style: const TextStyle(
                          color: Color(0xFFC8E6C9),
                          fontSize: 12,
                        ),
                      ),
                      if (grant.createdAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Dibuat ${_fmtDateTime(grant.createdAt!)}',
                          style: const TextStyle(
                            color: Color(0xFFC8E6C9),
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _revokingGrantId == grant.id
                              ? null
                              : () => _revokeAccess(grant),
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: Text(
                            _revokingGrantId == grant.id
                                ? 'Mencabut...'
                                : 'Cabut Akses',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Color(0x55FFFFFF)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xB3123323),
        border: Border.all(color: const Color(0x66FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFF1F8E9),
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _input({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(color: Color(0xFFEAF8EF)),
      decoration: _inputDecoration(label, hint: hint),
    );
  }

  InputDecoration _inputDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
      hintStyle: const TextStyle(color: Color(0x88EAF8EF)),
      filled: true,
      fillColor: Colors.white.withOpacity(0.06),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: Color(0xFF81C784)),
      ),
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x22184F2C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFEAF8EF),
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }

  String _fmtDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}
