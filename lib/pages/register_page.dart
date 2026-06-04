import 'package:flutter/material.dart';

import '../controllers/auth_controller.dart';
import '../services/auth_api_service.dart';
import '../widgets/portal_scaffold.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _authController = AuthController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authApiService = AuthApiService();
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitRegistration() async {
    if (!_formKey.currentState!.validate() || _isLoading) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _authApiService.register(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        role: 'user',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registrasi berhasil. Silakan login.'),
        ),
      );

      Navigator.pop(context);
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

  @override
  Widget build(BuildContext context) {
    return PortalScaffold(
      badge: 'AUTH ACCESS',
      title: 'Register User',
      subtitle: 'Create user account with local login',
      maxWidth: 460,
      actions: [
        PortalActionButton(
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onTap: () => Navigator.pop(context),
        ),
      ],
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _nameController,
              style: const TextStyle(color: Color(0xFFEAF8EF)),
              decoration: _inputDecoration('Full Name'),
              validator: (value) {
                return _authController.validateName(value);
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _emailController,
              style: const TextStyle(color: Color(0xFFEAF8EF)),
              decoration: _inputDecoration('Email'),
              validator: (value) {
                return _authController.validateEmail(value);
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordController,
              style: const TextStyle(color: Color(0xFFEAF8EF)),
              decoration: _inputDecoration('Password'),
              obscureText: true,
              validator: (value) {
                return _authController.validatePassword(value);
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: 'user',
              readOnly: true,
              style: const TextStyle(color: Color(0xFFEAF8EF)),
              decoration: _inputDecoration('Role').copyWith(
                helperText: 'Registration is limited to user role.',
                helperStyle: const TextStyle(color: Color(0xFFC8E6C9)),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _submitRegistration,
              child: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Register User'),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFFC8E6C9)),
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
