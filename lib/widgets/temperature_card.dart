import 'package:flutter/material.dart';

class TemperatureCard extends StatelessWidget {

  final double temp;
  final String status;
  final Color color;

  final String unit;
  final IconData icon;
  final bool compact;

  const TemperatureCard({
    super.key,
    required this.temp,
    required this.status,
    required this.color,
    this.unit = "°C",
    this.icon = Icons.thermostat,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {

    final cardHeight = compact ? 75.0 : 95.0;
    final iconSize = compact ? 26.0 : 32.0;
    final tempFont = compact ? 20.0 : 26.0;
    final statusFont = compact ? 11.0 : 13.0;

    return Container(

      height: cardHeight,

      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 10,
      ),

      decoration: BoxDecoration(

        color: const Color(0xFF2E7D32),

        borderRadius: BorderRadius.circular(14),

        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],

        border: Border.all(
          color: Colors.white.withOpacity(0.05),
        ),

      ),

      child: Row(

        children: [

          /// ICON CONTAINER
          Container(

            width: compact ? 40 : 48,
            height: compact ? 40 : 48,

            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),

            child: Icon(
              icon,
              size: iconSize,
              color: color,
            ),

          ),

          const SizedBox(width: 12),

          /// TEXT AREA
          Expanded(

            child: Column(

              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                /// TEMPERATURE (PRIORITY — NEVER SHRINK)
                Text(
                  "${temp.toStringAsFixed(1)} $unit",

                  maxLines: 1,

                  overflow: TextOverflow.visible,

                  style: TextStyle(
                    fontSize: tempFont,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFF1F8E9),
                  ),

                ),

                const SizedBox(height: 4),

                /// STATUS (CAN TRUNCATE)
                Text(
                  status,

                  maxLines: 1,

                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(
                    fontSize: statusFont,
                    color: const Color(0xFFB2DFDB),
                  ),

                ),

              ],

            ),

          ),

        ],

      ),

    );

  }

}