import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:async';

import 'device_selector_page.dart';
import 'login_page.dart';
import '../services/app_session_service.dart';
import '../services/push_notification_service.dart';

class SplashScreen extends StatefulWidget {

  final String deviceId;

  const SplashScreen({
    super.key,
    required this.deviceId,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();

}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {

  late AnimationController controller;

  late Animation<double> fadeIn;
  late Animation<double> fadeOut;
  late Animation<double> zoom;
  late Animation<double> blur;
  late Animation<double> glow;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );

    fadeIn = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: controller,
        curve: const Interval(0.0, 0.35, curve: Curves.easeOut),
      ),
    );

    fadeOut = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(
        parent: controller,
        curve: const Interval(0.75, 1.0, curve: Curves.easeIn),
      ),
    );

    zoom = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
      ),
    );

    blur = Tween<double>(begin: 6, end: 0).animate(
      CurvedAnimation(
        parent: controller,
        curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
      ),
    );

    glow = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: controller,
        curve: const Interval(0.2, 0.6, curve: Curves.easeOut),
      ),
    );

    start();
  }

  Future<void> start() async {
    await AppSessionService.restoreSession();
    if ((AppSessionService.token ?? '').isNotEmpty) {
      await PushNotificationService.onSessionAvailable();
    }
    await controller.forward();

    if (!mounted) return;

    final hasSession = (AppSessionService.token ?? '').isNotEmpty;
    final nextPage = hasSession
        ? const DeviceSelectorPage()
        : const LoginPage();

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(

        transitionDuration: const Duration(milliseconds: 700),

        pageBuilder: (_, __, ___) => nextPage,

        transitionsBuilder: (_, anim, __, child) {

          return FadeTransition(
            opacity: anim,
            child: child,
          );

        },

      ),
    );

  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final opacity = fadeIn.value * fadeOut.value;

          return Stack(
            alignment: Alignment.center,
            children: [
              _luxuryBackground(),
              BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: blur.value,
                  sigmaY: blur.value,
                ),
                child: const SizedBox.expand(),
              ),
              Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: zoom.value,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 28,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xCC0D2419),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: const Color(0x66FFFFFF),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.45),
                                  blurRadius: 36,
                                  offset: const Offset(0, 14),
                                ),
                                BoxShadow(
                                  color: const Color(0xFF66BB6A)
                                      .withOpacity(glow.value * 0.32),
                                  blurRadius: 50,
                                  spreadRadius: 1.5,
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    color: const Color(0x6681C784),
                                    border: Border.all(
                                      color: const Color(0x88D6F2D8),
                                    ),
                                  ),
                                  child: const Text(
                                    "SMART GREENHOUSE",
                                    style: TextStyle(
                                      color: Color(0xFFF1F8E9),
                                      fontSize: 11,
                                      letterSpacing: 1.2,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: const Color(0xAA173B2A),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0x55FFFFFF),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF81C784)
                                            .withOpacity(glow.value * 0.42),
                                        blurRadius: 40,
                                        spreadRadius: 1.5,
                                      ),
                                    ],
                                  ),
                                  child: Image.asset(
                                    "assets/logo/vitaroot.png",
                                    width: 150,
                                  ),
                                ),
                                const SizedBox(height: 22),
                                Text(
                                  "VitaRoot",
                                  style: TextStyle(
                                    fontSize: 34,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                    color: const Color(0xFFF7FCF8)
                                        .withOpacity(opacity),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  "Smart Plant Incubator System",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    letterSpacing: 0.9,
                                    color: const Color(0xFFD7EFDA)
                                        .withOpacity(opacity),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                const SizedBox(
                                  width: 170,
                                  child: LinearProgressIndicator(
                                    minHeight: 4,
                                    color: Color(0xFF9CCC65),
                                    backgroundColor: Color(0x55385C43),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );

  }

  Widget _luxuryBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF081E15), Color(0xFF113826), Color(0xFF2E7D32)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(color: const Color(0x66000000)),
          ),
          Positioned(
            top: -120,
            right: -90,
            child: _orb(const Color(0xAA66BB6A), 300),
          ),
          Positioned(
            bottom: -160,
            left: -80,
            child: _orb(const Color(0x8866BB6A), 340),
          ),
          Positioned(
            top: 180,
            left: 20,
            child: _orb(const Color(0x669CCC65), 140),
          ),
          Positioned(
            bottom: 140,
            right: 40,
            child: _orb(const Color(0x554CAF50), 120),
          ),
        ],
      ),
    );
  }

  Widget _orb(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: const SizedBox.expand(),
      ),
    );
  }

}

