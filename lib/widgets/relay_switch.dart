import 'package:flutter/material.dart';
import 'package:flutter_switch/flutter_switch.dart';

class RelaySwitch extends StatelessWidget {

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const RelaySwitch({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {

    return Padding(

      padding: const EdgeInsets.symmetric(vertical: 6),

      child: Row(

        children: [

          Icon(
            Icons.flash_on,
            color: value
                ? const Color(0xFF81C784)
                : Colors.white38,
          ),

          const SizedBox(width: 12),

          Expanded(

            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFFE8F5E9),
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),

          ),

          FlutterSwitch(

            width: 50,
            height: 26,

            value: value,

            toggleSize: 22,

            activeColor: const Color(0xFF66BB6A),

            inactiveColor: Colors.white24,

            disabled: !enabled,

            onToggle: onChanged,

          ),

        ],

      ),

    );

  }

}