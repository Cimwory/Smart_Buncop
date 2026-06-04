import 'package:flutter/material.dart';

class IndustrialCard extends StatelessWidget {

  final Widget child;

  const IndustrialCard({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {

    return Container(

      margin: const EdgeInsets.symmetric(vertical: 6),

      padding: const EdgeInsets.all(14),

      decoration: BoxDecoration(

        color: const Color.fromARGB(255, 7, 68, 10), // calm green

        borderRadius: BorderRadius.circular(14),

        boxShadow: [

          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),

        ],

      ),

      child: child,

    );

  }

}
