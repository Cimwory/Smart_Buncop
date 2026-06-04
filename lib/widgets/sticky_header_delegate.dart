import 'package:flutter/material.dart';

class StickyHeaderDelegate extends SliverPersistentHeaderDelegate {

  final double height;
  final Widget child;

  StickyHeaderDelegate({
    required this.height,
    required this.child,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {

    return Container(
      height: height,
      width: double.infinity,
      alignment: Alignment.center,
      child: child,
    );

  }

  @override
  bool shouldRebuild(covariant StickyHeaderDelegate oldDelegate) {

    return oldDelegate.height != height ||
           oldDelegate.child != child;

  }

}
