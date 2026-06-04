import 'package:flutter/material.dart';

class LabeledSlider extends StatelessWidget {

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String unit;
  final ValueChanged<double> onChanged;

  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions = 100,
    this.unit = '',
  });

  @override
  Widget build(BuildContext context) {

    return Column(

      crossAxisAlignment: CrossAxisAlignment.start,

      children: [

        /// LABEL + VALUE
        Row(

          children: [

            /// LABEL
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF1F8E9), // putih soft
                letterSpacing: 0.2,
              ),
            ),

            const Spacer(),

            /// VALUE
            Container(

              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 4,
              ),

              decoration: BoxDecoration(

                color: const Color(0xFF66BB6A).withOpacity(0.15),

                borderRadius: BorderRadius.circular(8),

                border: Border.all(
                  color: const Color(0xFF81C784).withOpacity(0.25),
                ),

              ),

              child: Text(
                "${value.toInt()}$unit",
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),

            ),

          ],

        ),

        const SizedBox(height: 8),

        /// SLIDER
        SliderTheme(

          data: SliderTheme.of(context).copyWith(

            activeTrackColor: const Color(0xFF66BB6A),

            inactiveTrackColor: Colors.white.withOpacity(0.15),

            thumbColor: const Color(0xFF81C784),

            overlayColor: const Color(0xFF81C784).withOpacity(0.15),

            trackHeight: 4,

            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 9,
            ),

          ),

          child: Slider(

            value: value,

            min: min,
            max: max,

            divisions: divisions,

            label: "${value.toInt()}$unit",

            onChanged: onChanged,

          ),

        ),

      ],

    );

  }

}