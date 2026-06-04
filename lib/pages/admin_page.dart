import 'package:flutter/material.dart';

import 'login_page.dart';
import 'super_admin_page.dart';
import 'user_page.dart';
import 'user_management_page.dart';
import '../services/activity_logger_service.dart';
import '../services/app_session_service.dart';
import '../services/auth_api_service.dart';
import '../services/push_notification_service.dart';
import '../widgets/portal_scaffold.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isSuperAdminSession = AppSessionService.role == 'super_admin';

    return PortalScaffold(
      badge: 'ADMIN ROLE',
      title: 'Admin Dashboard',
      subtitle: 'Kelola akses pengguna tanpa fitur log di aplikasi',
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
          icon: Icons.logout,
          label: 'Logout',
          onTap: () async {
            await ActivityLoggerService.log(
              action: 'auth.logout',
              module: 'auth',
              description: 'User logout dari halaman admin',
            );
            final token = AppSessionService.token;
            if (token != null && token.isNotEmpty) {
              try {
                await PushNotificationService.unregisterCurrentToken();
                await AuthApiService().logout(token: token);
              } catch (_) {}
            }
            await AppSessionService.clear();
            if (!context.mounted) return;
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const LoginPage()),
              (route) => false,
            );
          },
        ),
      ],
      child: Column(
        children: [
          PortalMenuTile(
            icon: Icons.manage_accounts,
            title: 'User Directory',
            subtitle: 'View user list and current role',
            accent: const Color(0xFF81C784),
            onTap: () {
              ActivityLoggerService.log(
                action: 'screen.open',
                module: 'admin',
                description: 'Membuka halaman user directory',
              );
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const UserManagementPage(allowRoleEdit: false),
                ),
              );
            },
          ),
          PortalMenuTile(
            icon: Icons.person_outline,
            title: 'User Profile',
            subtitle: 'Open profile page',
            accent: const Color(0xFF9CCC65),
            onTap: () {
              ActivityLoggerService.log(
                action: 'screen.open',
                module: 'user',
                description: 'Membuka halaman user profile',
              );
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UserPage()),
              );
            },
          ),
        ],
      ),
    );
  }
}
