import 'package:flutter/material.dart';

class HeaderWidget extends StatelessWidget {

  final String timeSource;

  const HeaderWidget({
    super.key,
    required this.timeSource,
  });

  @override
  Widget build(BuildContext context) {

    return Container(

      width: double.infinity,

      color: const Color(0xFF1B5E20), // ✅ BACKGROUND SOLID (tidak transparan)

      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ),

      child: Row(

        mainAxisAlignment: MainAxisAlignment.spaceBetween,

        crossAxisAlignment: CrossAxisAlignment.center,

        children: [

          const Column(

            mainAxisAlignment: MainAxisAlignment.center,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              Text(
                "Smart Inkubator",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),

              SizedBox(height: 4),

              Text(
                "Monitoring & Kontrol Tanaman",
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                ),
              ),

            ],

          ),

          Text(
            timeSource,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),

        ],

      ),

    );

  }

}
