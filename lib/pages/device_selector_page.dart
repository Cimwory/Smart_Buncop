import 'dart:ui';

import 'package:flutter/material.dart';

import 'indoor_farming_page.dart';
import 'inkubator_page.dart';
import 'login_page.dart';
import 'monitoring_buncop_page.dart';
import 'nutrimix_page.dart';
import 'user_page.dart';
import '../config/app_config.dart';
import '../services/activity_logger_service.dart';
import '../services/app_session_service.dart';
import '../services/auth_api_service.dart';
import '../services/push_notification_service.dart';
import '../widgets/portal_scaffold.dart';

class DeviceSelectorPage extends StatefulWidget {
  const DeviceSelectorPage({super.key});

  @override
  State<DeviceSelectorPage> createState() => _DeviceSelectorPageState();
}

class _DeviceSelectorPageState extends State<DeviceSelectorPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathController;
  late final Animation<double> _iconScale;
  late final Animation<double> _iconGlow;
  late final PageController _pageController;

  int _currentIndex = 0;
  double _pageValue = 0;
  bool _isLoggingOut = false;

  late final List<_DeviceOption> _options;
  final AuthApiService _authApiService = AuthApiService();

  @override
  void initState() {
    super.initState();

    ActivityLoggerService.log(
      action: 'screen.open',
      module: 'navigation',
      description: 'Membuka halaman pemilihan perangkat',
    );

    _options = [
      _DeviceOption(
        icon: Icons.local_florist,
        label: 'Inkubator',
        subtitle: AppConfig.inkubatorDeviceId.isNotEmpty
            ? 'Monitoring suhu, kelembapan, dan status inkubator'
            : 'Device ID belum dikonfigurasi',
        accent: const Color(0xFF81C784),
        pageBuilder: () => AppConfig.inkubatorDeviceId.isNotEmpty
            ? const InkubatorPage(deviceId: AppConfig.inkubatorDeviceId)
            : const _ConfigRequiredPage(
                message:
                    'Set --dart-define=BUNCOP_DEVICE_INKUBATOR=<device_id>',
              ),
      ),
      _DeviceOption(
        icon: Icons.science,
        label: 'Nutrimix',
        subtitle: AppConfig.nutrimixDeviceId.isNotEmpty
            ? 'Kontrol pencampuran nutrisi'
            : 'Device ID belum dikonfigurasi',
        accent: const Color(0xFF66BB6A),
        pageBuilder: () => AppConfig.nutrimixDeviceId.isNotEmpty
            ? const NutrimixPage(deviceId: AppConfig.nutrimixDeviceId)
            : const _ConfigRequiredPage(
                message:
                    'Set --dart-define=BUNCOP_DEVICE_NUTRIMIX=<device_id>',
              ),
      ),
      _DeviceOption(
        icon: Icons.monitor_heart_outlined,
        label: 'Monitoring Buncob',
        subtitle: 'Monitoring area multi ESP',
        accent: const Color(0xFFA5D6A7),
        pageBuilder: () => const MonitoringBuncopPage(),
      ),
      _DeviceOption(
        icon: Icons.warehouse_outlined,
        label: 'Indoor Farming',
        subtitle: 'Monitoring nutrisi, tandon RO, dan status indoor farming',
        accent: const Color(0xFFB2DF8A),
        pageBuilder: () => const IndoorFarmingPage(),
      ),
    ];

    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat(reverse: true);

    _iconScale = Tween<double>(begin: 0.96, end: 1.1).animate(
      CurvedAnimation(parent: _breathController, curve: Curves.easeInOutSine),
    );

    _iconGlow = Tween<double>(begin: 0.25, end: 0.8).animate(
      CurvedAnimation(parent: _breathController, curve: Curves.easeInOutSine),
    );

    _pageController = PageController(viewportFraction: 0.78)
      ..addListener(() {
        final value = _pageController.page ?? _pageController.initialPage.toDouble();
        if (!mounted) return;
        setState(() {
          _pageValue = value;
          _currentIndex = value.round().clamp(0, _options.length - 1);
        });
      });
  }

  @override
  void dispose() {
    _breathController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _backgroundLayer(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: () {
                                Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(builder: (_) => const UserPage()),
                                );
                              },
                              child: Ink(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xAA113021),
                                  border: Border.all(color: const Color(0x66FFFFFF)),
                                ),
                                child: const Icon(
                                  Icons.person_rounded,
                                  color: Color(0xFFE8F5E9),
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          PortalActionButton(
                            icon: Icons.logout,
                            label: _isLoggingOut ? 'Logging out...' : 'Logout',
                            onTap: () {
                              if (_isLoggingOut) return;
                              _logout();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _heroHeader(),
                      const SizedBox(height: 16),
                      _glassPanel(
                        child: Column(
                          children: [
                            const Text(
                              'Powered by',
                              style: TextStyle(
                                color: Color(0xFFD4EFE5),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 14,
                              runSpacing: 10,
                              children: [
                                _partnerLogo('assets/logo/danantara.png'),
                                _partnerLogo('assets/logo/petrokimia.png'),
                                _partnerLogo('assets/logo/pupukindonesia.png'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _glassPanel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Pilih perangkat yang ingin dipantau',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0xFFEAF8EF),
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Geser kanan/kiri untuk fokus ke perangkat',
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.72),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              height: 190,
                              child: PageView.builder(
                                controller: _pageController,
                                itemCount: _options.length,
                                onPageChanged: (index) {
                                  setState(() => _currentIndex = index);
                                },
                                itemBuilder: (context, index) {
                                  final option = _options[index];
                                  final distance = (_pageValue - index).abs();
                                  final t = (1 - distance).clamp(0.0, 1.0);
                                  final scale = 0.88 + (0.12 * t);
                                  final opacity = 0.55 + (0.45 * t);

                                  return Transform.scale(
                                    scale: scale,
                                    child: Opacity(
                                      opacity: opacity,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                        child: _deviceCard(option: option, focused: index == _currentIndex),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(_options.length, (index) {
                                final active = index == _currentIndex;
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  margin: const EdgeInsets.symmetric(horizontal: 4),
                                  width: active ? 22 : 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    color: active
                                        ? _options[_currentIndex].accent
                                        : Colors.white.withOpacity(0.35),
                                  ),
                                );
                              }),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _backgroundLayer() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0B2C1B), Color(0xFF184F34), Color(0xFF2E7D32)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              color: const Color(0x66000000),
            ),
          ),
          Positioned(
            top: -90,
            right: -70,
            child: _blurOrb(const Color(0x8058B66A), 220),
          ),
          Positioned(
            bottom: -110,
            left: -90,
            child: _blurOrb(const Color(0x8066BB6A), 260),
          ),
          Positioned(
            top: 140,
            left: -30,
            child: _blurOrb(const Color(0x668BC34A), 140),
          ),
        ],
      ),
    );
  }

  Widget _heroHeader() {
    return _glassPanel(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: const Color(0x6681C784),
              border: Border.all(color: const Color(0x88C8E6C9)),
            ),
            child: const Text(
              'SMART GREENHOUSE',
              style: TextStyle(
                color: Color(0xFFE8F5E9),
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Image.asset('assets/logo/vitaroot.png', height: 90),
          const SizedBox(height: 12),
          const Text(
            'VitaRoot',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: Color(0xFFF1F8E9),
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Smart Plant Incubator System',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFC8E6C9),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassPanel({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xCC0F2A1C),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0x55FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 22,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _blurOrb(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _partnerLogo(String path) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xAA113021),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x66FFFFFF)),
      ),
      child: SizedBox(
        height: 22,
        child: Image.asset(path, fit: BoxFit.contain),
      ),
    );
  }

  Widget _deviceCard({required _DeviceOption option, required bool focused}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [
            option.accent.withOpacity(focused ? 0.50 : 0.35),
            const Color(0xAA103425),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: Colors.white.withOpacity(focused ? 0.45 : 0.28),
        ),
        boxShadow: [
          BoxShadow(
            color: option.accent.withOpacity(focused ? 0.34 : 0.2),
            blurRadius: focused ? 30 : 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            Navigator.push(context, _industrialRoute(option.pageBuilder()));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 320;
                final icon = AnimatedBuilder(
                  animation: _breathController,
                  builder: (context, child) {
                    final pulse = focused ? _iconScale.value : 1.0;
                    return Transform.scale(
                      scale: pulse,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.1),
                          boxShadow: [
                            BoxShadow(
                              color: option.accent.withOpacity(
                                focused ? _iconGlow.value * 0.55 : 0.2,
                              ),
                              blurRadius: 14,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Icon(option.icon, size: 22, color: option.accent),
                      ),
                    );
                  },
                );

                final titleSection = Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFF1F8E9),
                          letterSpacing: 0.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        option.subtitle,
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFC8E6C9),
                        ),
                      ),
                    ],
                  ),
                );

                final openBadge = FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xAA113021),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0x66FFFFFF)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'OPEN',
                          style: TextStyle(
                            color: Color(0xFFE8F5E9),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.7,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 16,
                          color: option.accent,
                        ),
                      ],
                    ),
                  ),
                );

                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          icon,
                          const SizedBox(width: 12),
                          titleSection,
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: openBadge,
                      ),
                    ],
                  );
                }

                return Row(
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    titleSection,
                    const SizedBox(width: 8),
                    openBadge,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Route _industrialRoute(Widget page) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      reverseTransitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final slide = Tween<Offset>(
          begin: const Offset(0.15, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        );

        final fade = Tween<double>(begin: 0, end: 1).animate(animation);

        final scale = Tween<double>(begin: 0.97, end: 1).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        );

        return FadeTransition(
          opacity: fade,
          child: SlideTransition(
            position: slide,
            child: ScaleTransition(scale: scale, child: child),
          ),
        );
      },
    );
  }

  Future<void> _logout() async {
    if (_isLoggingOut) return;

    setState(() => _isLoggingOut = true);
    final token = AppSessionService.token;

    await ActivityLoggerService.log(
      action: 'auth.logout',
      module: 'auth',
      description: 'User logout dari halaman device selector',
    );

    try {
      await PushNotificationService.unregisterCurrentToken();
      if (token != null && token.isNotEmpty) {
        await _authApiService.logout(token: token);
      }
    } finally {
      await AppSessionService.clear();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      }
    }
  }

}

class _DeviceOption {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color accent;
  final Widget Function() pageBuilder;

  const _DeviceOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.accent,
    required this.pageBuilder,
  });
}

class _ConfigRequiredPage extends StatelessWidget {
  final String message;

  const _ConfigRequiredPage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Konfigurasi Dibutuhkan')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            message,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
