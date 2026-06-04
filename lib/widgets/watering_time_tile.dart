import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'industrial_card.dart';

class WateringTimeTile extends StatelessWidget {

  final int index;
  final TimeOfDay time;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const WateringTimeTile({
    super.key,
    required this.index,
    required this.time,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {

    return IndustrialCard(

      child: Row(

        children: [

          /// ICON CONTAINER
          Container(

            padding: const EdgeInsets.all(10),

            decoration: BoxDecoration(

              color: const Color(0xFF81C784).withOpacity(0.15),

              borderRadius: BorderRadius.circular(10),

            ),

            child: const Icon(
              CupertinoIcons.drop_fill,
              color: Color(0xFF81C784),
              size: 20,
            ),

          ),

          const SizedBox(width: 14),

          /// TEXT
          Expanded(

            child: Column(

              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                Text(
                  "Siraman ${index + 1}",
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE8F5E9),
                  ),
                ),

                const SizedBox(height: 2),

                Text(
                  time.format(context),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFB2DFDB),
                  ),
                ),

              ],

            ),

          ),

          /// BUTTONS
          Row(

            children: [

              _actionButton(
                icon: CupertinoIcons.pencil,
                color: const Color(0xFF81C784),
                onTap: onEdit,
              ),

              const SizedBox(width: 6),

              _actionButton(
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


  Widget _actionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
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