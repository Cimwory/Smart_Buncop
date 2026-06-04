import 'package:flutter/material.dart';
import '../domain/repositories/device_repository.dart';
import 'industrial_card.dart';

class EspStatusCard extends StatelessWidget {

  final DeviceRepository service;

  const EspStatusCard({
    super.key,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {

    return StreamBuilder<bool>(

      stream: service.espOnlineStream(),

      builder: (context, snap) {

        final online = snap.data ?? false;

        final statusColor = online
            ? const Color(0xFF66BB6A)
            : const Color(0xFFE57373);

        return IndustrialCard(

          child: Row(

            children: [

              /// ICON CONTAINER (stable size)
              Container(

                width: 42,
                height: 42,

                decoration: BoxDecoration(

                  color: statusColor.withOpacity(0.15),

                  borderRadius: BorderRadius.circular(10),

                ),

                child: Icon(
                  online
                      ? Icons.wifi
                      : Icons.wifi_off,
                  color: statusColor,
                  size: 22,
                ),

              ),

              const SizedBox(width: 12),

              /// TEXT SECTION (ANTI OVERFLOW)
              Expanded(

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  mainAxisSize: MainAxisSize.min,

                  children: [

                    Text(
                      online
                          ? "ESP32 Online"
                          : "ESP32 Offline",

                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,

                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF1F8E9),
                      ),

                    ),

                    const SizedBox(height: 2),

                    Text(
                      online
                          ? "Perangkat terhubung dan aktif"
                          : "Perangkat tidak terhubung",

                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,

                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFB2DFDB),
                      ),

                    ),

                  ],

                ),

              ),

              /// STATUS DOT
              Container(

                width: 10,
                height: 10,

                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),

              ),

            ],

          ),

        );

      },

    );

  }

}
