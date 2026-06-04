import 'package:flutter/material.dart';

import 'admin_page.dart';
import 'backend_control_page.dart';
import 'login_page.dart';
import 'user_page.dart';
import 'user_management_page.dart';
import '../services/activity_logger_service.dart';
import '../services/app_session_service.dart';
import '../services/auth_api_service.dart';
import '../services/push_notification_service.dart';
import '../widgets/portal_scaffold.dart';

class SuperAdminPage extends StatelessWidget {
  const SuperAdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PortalScaffold(
      badge: 'SUPER ADMIN',
      title: 'Control Center',
      subtitle: 'Manage user role and backend control entry',
      actions: [
        PortalActionButton(
          icon: Icons.logout,
          label: 'Logout',
          onTap: () async {
            await ActivityLoggerService.log(
              action: 'auth.logout',
              module: 'auth',
              description: 'User logout dari halaman super admin',
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PortalMenuTile(
            icon: Icons.admin_panel_settings_outlined,
            title: 'Role Management',
            subtitle: 'Set role akun user (super_admin/admin/user)',
            accent: const Color(0xFFA5D6A7),
            onTap: () {
              ActivityLoggerService.log(
                action: 'screen.open',
                module: 'admin',
                description: 'Membuka halaman role management',
              );
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const UserManagementPage(allowRoleEdit: true),
                ),
              );
            },
          ),
          PortalMenuTile(
            icon: Icons.settings_input_component,
            title: 'Backend Control',
            subtitle: 'Gateway for server, API, and integration controls',
            accent: const Color(0xFF81C784),
            onTap: () {
              ActivityLoggerService.log(
                action: 'screen.open',
                module: 'admin',
                description: 'Membuka halaman backend control',
              );
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BackendControlPage()),
              );
            },
          ),
          PortalMenuTile(
            icon: Icons.admin_panel_settings,
            title: 'Open Admin Dashboard',
            subtitle: 'Access admin features as super admin',
            accent: const Color(0xFF66BB6A),
            onTap: () {
              ActivityLoggerService.log(
                action: 'screen.open',
                module: 'admin',
                description: 'Membuka halaman admin dashboard',
              );
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AdminPage()),
              );
            },
          ),
          PortalMenuTile(
            icon: Icons.person_outline,
            title: 'Open User Profile',
            subtitle: 'View profile page as user perspective',
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
