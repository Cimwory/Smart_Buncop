import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'admin_page.dart';
import '../config/app_config.dart';
import '../controllers/auth_controller.dart';
import 'register_page.dart';
import 'super_admin_page.dart';
import 'user_page.dart';
import '../widgets/portal_scaffold.dart';
import '../services/activity_logger_service.dart';
import '../services/app_session_service.dart';
import '../services/auth_api_service.dart';
import '../services/push_notification_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authController = AuthController();
  final _authApiService = AuthApiService();

  bool _isLoading = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate() || _isLoading) return;

    setState(() => _isLoading = true);

    try {
      final loginResult = await _authApiService.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      if (!mounted) return;

      await AppSessionService.setSession(
        id: loginResult.user.id,
        roleValue: loginResult.user.role,
        emailValue: loginResult.user.email,
        tokenValue: loginResult.token,
      );
      await PushNotificationService.onSessionAvailable();

      await ActivityLoggerService.log(
        action: 'auth.login',
        module: 'auth',
        description: 'Login berhasil dengan email/password, role: ${loginResult.user.role}',
        metadata: {'role': loginResult.user.role, 'auth_provider': 'email'},
      );

      _openRolePage(loginResult.user.role);
    } on AuthApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loginWithSso() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);

    try {
      final authUrl = await _authApiService.getSsoAuthUrl(channel: 'mobile');
      final callback = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: 'buncop',
      );

      final callbackUri = Uri.parse(callback);
      final code = callbackUri.queryParameters['code'] ?? '';
      if (code.isEmpty) {
        throw const AuthApiException('Kode callback SSO tidak ditemukan');
      }

      final loginResult = await _authApiService.exchangeSsoCode(code: code);

      if (!mounted) return;

      await AppSessionService.setSession(
        id: loginResult.user.id,
        roleValue: loginResult.user.role,
        emailValue: loginResult.user.email,
        tokenValue: loginResult.token,
      );
      await PushNotificationService.onSessionAvailable();

      await ActivityLoggerService.log(
        action: 'auth.login',
        module: 'auth',
        description: 'Login berhasil via SSO Keycloak, role: ${loginResult.user.role}',
        metadata: {
          'role': loginResult.user.role,
          'auth_provider': 'keycloak',
        },
      );

      _openRolePage(loginResult.user.role);
    } on AuthApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      final rawMessage = [
        e.code,
        e.message ?? '',
      ].where((part) => part.trim().isNotEmpty).join(': ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('SSO error: $rawMessage')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('SSO gagal: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _openRolePage(String role) {
    Widget page;
    switch (role) {
      case AuthController.roleSuperAdmin:
        page = const SuperAdminPage();
        break;
      case AuthController.roleAdmin:
        page = const AdminPage();
        break;
      default:
        page = const UserPage();
        break;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }
  @override
  Widget build(BuildContext context) {
    final hasApiBase = AppConfig.apiBase.trim().isNotEmpty;

    return PortalScaffold(
      badge: 'AUTH ACCESS',
      title: 'Login',
      subtitle: 'Sign in using backend account to access your dashboard',
      maxWidth: 460,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _emailController,
              style: const TextStyle(color: Color(0xFFEAF8EF)),
              decoration: _inputDecoration('Email'),
              validator: _authController.validateEmail,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordController,
              style: const TextStyle(color: Color(0xFFEAF8EF)),
              decoration: _inputDecoration(
                'Password',
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() => _showPassword = !_showPassword);
                  },
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                    color: const Color(0xFFC8E6C9),
                  ),
                ),
              ),
              obscureText: !_showPassword,
              validator: _authController.validatePassword,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: (_isLoading || !hasApiBase) ? null : _login,
              child: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Login'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: (_isLoading || !hasApiBase) ? null : _loginWithSso,
              child: const Text('login sso'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: (_isLoading || !hasApiBase)
                  ? null
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const RegisterPage(),
                        ),
                      );
                    },
              child: const Text('Register'),
            ),
            if (!hasApiBase) ...[
              const SizedBox(height: 8),
              const Text(
                'BUNCOP_API_BASE belum di-set. Jalankan dengan --dart-define=BUNCOP_API_BASE=<URL_API>',
                style: TextStyle(color: Color(0xFFFFCDD2), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, {Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
      suffixIcon: suffixIcon,
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
}
