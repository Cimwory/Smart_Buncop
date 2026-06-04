import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../services/app_session_service.dart';
import '../widgets/portal_scaffold.dart';
import 'device_selector_page.dart';
import 'super_admin_page.dart';

class UserPage extends StatefulWidget {
  const UserPage({super.key});

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  static String get _baseUrl => AppConfig.requireApiBase();

  late Future<_UserProfile> _futureProfile;

  @override
  void initState() {
    super.initState();
    _futureProfile = _fetchProfile();
  }

  Future<_UserProfile> _fetchProfile() async {
    if ((AppSessionService.token ?? '').isEmpty &&
        (AppSessionService.email ?? '').toLowerCase() == 'guest@local') {
      return const _UserProfile(
        name: 'Guest',
        email: 'guest@local',
        role: 'user',
        authProvider: 'guest',
      );
    }

    final uri = Uri.parse('$_baseUrl/auth/me');
    final response = await http.get(
      uri,
      headers: AppSessionService.buildAuthHeaders(json: false),
    );

    if (response.statusCode >= 400) {
      throw Exception('Gagal memuat profil (${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Format respon profil tidak valid');
    }

    final rawProfile = decoded['data'] ?? decoded['user'];
    if (rawProfile is! Map<String, dynamic>) {
      throw Exception('Data profil tidak ditemukan');
    }

    return _UserProfile.fromJson(rawProfile);
  }

  Future<void> _reload() async {
    setState(() {
      _futureProfile = _fetchProfile();
    });
    await _futureProfile;
  }

  @override
  Widget build(BuildContext context) {
    final isSuperAdminSession = AppSessionService.role == 'super_admin';

    return PortalScaffold(
      badge: 'USER ROLE',
      title: 'User Profile',
      subtitle: 'Informasi akun user',
      actions: [
        if (isSuperAdminSession)
          PortalActionButton(
            icon: Icons.arrow_back_rounded,
            label: 'Back',
            onTap: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const SuperAdminPage()),
              );
            },
          ),
        PortalActionButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onTap: _reload,
        ),
      ],
      child: FutureBuilder<_UserProfile>(
        future: _futureProfile,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError) {
            return _errorState(snapshot.error.toString());
          }

          final profile = snapshot.data;
          if (profile == null) {
            return _errorState('Profil user kosong');
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PortalMenuTile(
                icon: Icons.badge_outlined,
                title: profile.name,
                subtitle: profile.email,
                accent: const Color(0xFFA5D6A7),
                trailing: _pill(profile.role.toUpperCase()),
              ),
              const SizedBox(height: 6),
              PortalMenuTile(
                icon: Icons.verified_user_outlined,
                title: 'Role',
                subtitle: profile.role,
                accent: const Color(0xFF81C784),
                trailing: const SizedBox.shrink(),
              ),
              if (profile.employeeId != null && profile.employeeId!.isNotEmpty) ...[
                const SizedBox(height: 6),
                PortalMenuTile(
                  icon: Icons.numbers_outlined,
                  title: 'Employee ID',
                  subtitle: profile.employeeId!,
                  accent: const Color(0xFF81C784),
                  trailing: const SizedBox.shrink(),
                ),
              ],
              if (profile.authProvider != null && profile.authProvider!.isNotEmpty) ...[
                const SizedBox(height: 6),
                PortalMenuTile(
                  icon: Icons.login_rounded,
                  title: 'Auth Provider',
                  subtitle: profile.authProvider!,
                  accent: const Color(0xFF81C784),
                  trailing: const SizedBox.shrink(),
                ),
              ],
              const SizedBox(height: 10),
              ElevatedButton.icon(
                icon: const Icon(Icons.memory),
                label: const Text('Menu Utama'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DeviceSelectorPage()),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x334CAF50),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFE8F5E9),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _errorState(String message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Gagal memuat profil user.',
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
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Coba Lagi'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DeviceSelectorPage()),
            );
          },
          icon: const Icon(Icons.memory),
          label: const Text('Open Device Selector'),
        ),
      ],
    );
  }
}

class _UserProfile {
  final String name;
  final String email;
  final String role;
  final String? authProvider;
  final String? ssoSubject;
  final String? employeeId;

  const _UserProfile({
    required this.name,
    required this.email,
    required this.role,
    this.authProvider,
    this.ssoSubject,
    this.employeeId,
  });

  factory _UserProfile.fromJson(Map<String, dynamic> json) {
    return _UserProfile(
      name: json['name']?.toString() ?? '-',
      email: json['email']?.toString() ?? '-',
      role: json['role']?.toString() ?? 'user',
      authProvider: json['auth_provider']?.toString(),
      ssoSubject: json['sso_subject']?.toString(),
      employeeId: json['employee_id']?.toString(),
    );
  }
}
