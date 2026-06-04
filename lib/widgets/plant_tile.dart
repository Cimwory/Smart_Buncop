import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'industrial_card.dart';

class PlantTile extends StatelessWidget {
  final String id;
  final Map<String, dynamic> data;
  final bool isActive;
  final bool enabled;
  final VoidCallback? onActivateToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const PlantTile({
    super.key,
    required this.id,
    required this.data,
    required this.isActive,
    this.onActivateToggle,
    required this.onEdit,
    required this.onDelete,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final canActivate = enabled && onActivateToggle != null;

    final name = data['name'] ?? id;
    final pwm = data['light_pwm'] ?? 0;
    final tempOptimal = data['temp_optimal'];
    final minTemp = (tempOptimal is Map ? tempOptimal['min'] : null) ?? 0;
    final maxTemp = (tempOptimal is Map ? tempOptimal['max'] : null) ?? 0;

    final lightCycleRaw = data['light_cycle'];
    final lightCycle =
        lightCycleRaw is Map ? Map<String, dynamic>.from(lightCycleRaw) : {};
    final darkDays = (lightCycle['dark_days'] as num?)?.toInt() ?? 7;
    final lightDays = (lightCycle['light_days'] as num?)?.toInt() ?? 7;
    final startDate = lightCycle['start_date']?.toString() ?? '-';

    return IndustrialCard(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? Colors.green.withOpacity(0.15)
                  : Colors.white.withOpacity(0.05),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: Colors.green.withOpacity(0.6),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
            ),
            child: Icon(
              CupertinoIcons.leaf_arrow_circlepath,
              color: isActive ? const Color(0xFF81C784) : Colors.white54,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE8F5E9),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "PWM $pwm%  -  $minTemp-$maxTemp C",
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFB2DFDB),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "Gelap $darkDays hari -> Terang $lightDays hari (mulai $startDate)",
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFC8E6C9),
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              _iconButton(
                icon: CupertinoIcons.power,
                color: !canActivate
                    ? Colors.grey
                    : isActive
                    ? Colors.redAccent
                    : const Color(0xFF66BB6A),
                onTap: canActivate ? onActivateToggle : null,
              ),
              const SizedBox(width: 4),
              _iconButton(
                icon: CupertinoIcons.pencil,
                color: const Color(0xFF81C784),
                onTap: onEdit,
              ),
              const SizedBox(width: 4),
              _iconButton(
                icon: CupertinoIcons.trash,
                color: Colors.redAccent,
                onTap: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 18,
          color: color,
        ),
      ),
    );
  }
}
