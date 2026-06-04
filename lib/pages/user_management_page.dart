import 'package:flutter/material.dart';

import '../services/activity_logger_service.dart';
import '../services/app_session_service.dart';
import '../services/user_access_api_service.dart';
import '../widgets/portal_scaffold.dart';

class UserManagementPage extends StatefulWidget {
  final bool allowRoleEdit;
  final bool allowStatusEdit;

  const UserManagementPage({
    super.key,
    this.allowRoleEdit = false,
    this.allowStatusEdit = true,
  });

  @override
  State<UserManagementPage> createState() => _UserManagementPageState();
}

class _UserManagementPageState extends State<UserManagementPage> {
  final _service = UserAccessApiService();
  late Future<List<AccessUser>> _futureUsers;
  List<String> _roles = const ['super_admin', 'admin', 'user'];
  final Set<int> _savingUserIds = <int>{};
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _futureUsers = _loadUsers();
    _loadRoles();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRoles() async {
    try {
      final roles = await _service.listRoles();
      if (!mounted) return;
      setState(() {
        _roles = roles;
      });
    } catch (_) {
      // Keep fallback roles when request fails.
    }
  }

  Future<List<AccessUser>> _loadUsers() {
    return _service.listUsers();
  }

  Future<void> _reload() async {
    setState(() {
      _futureUsers = _loadUsers();
    });
    await _futureUsers;
  }

  Future<void> _updateRole(AccessUser user, String role) async {
    if (_savingUserIds.contains(user.id)) return;

    setState(() => _savingUserIds.add(user.id));
    try {
      await _service.updateUserRole(userId: user.id, role: role);
      await ActivityLoggerService.log(
        action: 'admin.user.role.change',
        module: 'admin',
        description: 'Mengubah role user "${user.email}" menjadi $role',
        metadata: {'target_user_id': user.id, 'target_email': user.email, 'new_role': role},
      );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Role ${user.email} diubah ke $role')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _savingUserIds.remove(user.id));
      }
    }
  }

  Future<void> _updateActive(AccessUser user, bool isActive) async {
    if (_savingUserIds.contains(user.id)) return;

    setState(() => _savingUserIds.add(user.id));
    try {
      await _service.updateUserActive(userId: user.id, isActive: isActive);
      await ActivityLoggerService.log(
        action: isActive ? 'admin.user.unsuspend' : 'admin.user.suspend',
        module: 'admin',
        description: isActive
            ? 'Mengaktifkan kembali user "${user.email}"'
            : 'Menangguhkan user "${user.email}"',
        metadata: {'target_user_id': user.id, 'target_email': user.email, 'is_active': isActive},
      );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Status ${user.email} menjadi ${isActive ? 'aktif' : 'nonaktif'}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _savingUserIds.remove(user.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSuperAdminView = widget.allowRoleEdit;

    return PortalScaffold(
      badge: isSuperAdminView ? 'SUPER ADMIN' : 'ADMIN ROLE',
      title: isSuperAdminView ? 'Role Management' : 'User Directory',
      subtitle: isSuperAdminView
          ? 'Set role akun user dari backend'
          : 'View registered users and current role',
      actions: [
        PortalActionButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onTap: _reload,
        ),
        PortalActionButton(
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onTap: () => Navigator.pop(context),
        ),
      ],
      child: FutureBuilder<List<AccessUser>>(
        future: _futureUsers,
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

          final users = snapshot.data ?? const <AccessUser>[];
          if (users.isEmpty) {
            return const Text(
              'Belum ada user di database.',
              style: TextStyle(color: Color(0xFFD9F2DD)),
            );
          }

          final keyword = _searchCtrl.text.trim().toLowerCase();
          final filteredUsers = users.where((user) {
            if (keyword.isEmpty) return true;
            return user.name.toLowerCase().contains(keyword) ||
                user.email.toLowerCase().contains(keyword) ||
                user.role.toLowerCase().contains(keyword);
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _summaryHeader(users, filteredUsers.length),
              const SizedBox(height: 10),
              TextField(
                controller: _searchCtrl,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Color(0xFFEAF8EF)),
                decoration: InputDecoration(
                  labelText: 'Search user',
                  labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
                  prefixIcon: const Icon(Icons.search, color: Color(0xFFC8E6C9)),
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
                ),
              ),
              const SizedBox(height: 10),
              if (filteredUsers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Tidak ada user sesuai pencarian.',
                    style: TextStyle(color: Color(0xFFD9F2DD)),
                  ),
                ),
              ...filteredUsers.map((user) {
              final isCurrentUser = AppSessionService.userId == user.id;
              final isSaving = _savingUserIds.contains(user.id);

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: const Color(0xB3123323),
                  border: Border.all(color: const Color(0x66FFFFFF)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.person_outline, color: Color(0xFFEAF8EF)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.name,
                                style: const TextStyle(
                                  color: Color(0xFFF1F8E9),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                user.email,
                                style: const TextStyle(color: Color(0xFFD9F2DD)),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Auth: ${user.authProvider}',
                                style: const TextStyle(
                                  color: Color(0xFFC8E6C9),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _rolePill(user.role),
                        _statusPill(user.isActive),
                        if (widget.allowStatusEdit)
                          SizedBox(
                            width: 96,
                            child: OutlinedButton(
                              onPressed: isSaving || isCurrentUser
                                  ? null
                                  : () => _updateActive(user, !user.isActive),
                              child: Text(
                                user.isActive ? 'Suspend' : 'Activate',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (isSuperAdminView) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: _roles.contains(user.role) ? user.role : 'user',
                        items: _roles
                            .map(
                              (role) => DropdownMenuItem<String>(
                                value: role,
                                child: Text(role),
                              ),
                            )
                            .toList(),
                        onChanged: (isSaving || (isCurrentUser && user.role == 'super_admin'))
                            ? null
                            : (value) {
                                if (value == null || value == user.role) return;
                                _updateRole(user, value);
                              },
                        decoration: const InputDecoration(
                          labelText: 'Set Role',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
            ],
          );
        },
      ),
    );
  }

  Widget _statusPill(bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? const Color(0x334CAF50) : const Color(0x33F44336),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isActive ? 'ACTIVE' : 'INACTIVE',
        style: TextStyle(
          color: isActive ? const Color(0xFFE8F5E9) : const Color(0xFFFFCDD2),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _summaryHeader(List<AccessUser> users, int filteredCount) {
    final total = users.length;
    final active = users.where((u) => u.isActive).length;
    final admin = users.where((u) => u.role == 'admin').length;
    final superAdmin = users.where((u) => u.role == 'super_admin').length;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _summaryChip('Total', '$total'),
        _summaryChip('Filtered', '$filteredCount'),
        _summaryChip('Active', '$active'),
        _summaryChip('Admin', '$admin'),
        _summaryChip('Super Admin', '$superAdmin'),
      ],
    );
  }

  Widget _summaryChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x331B5E20),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x6681C784)),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          color: Color(0xFFE8F5E9),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _rolePill(String role) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x334CAF50),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        role.toUpperCase(),
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
          'Gagal memuat user.',
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
