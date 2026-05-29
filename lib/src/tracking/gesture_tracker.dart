import 'package:flutter/widgets.dart';

import '../core/sdk_scope.dart';
import '../logger/logger.dart';

/// Wrap your root widget with [UnilitixGestureDetector] to enable
/// automatic tap and rage-tap tracking:
///
/// ```dart
/// runApp(UnilitixGestureDetector(child: MyApp()));
/// ```
class UnilitixGestureDetector extends StatelessWidget {
  final Widget child;

  const UnilitixGestureDetector({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (details) {
        final pos = details.globalPosition;
        final screen = SdkScope.currentScreen ?? 'unknown';
        UnilitixLogger.d(
            'Tap @ ${pos.dx.toInt()},${pos.dy.toInt()} on $screen');
        SdkScope.onTap?.call(screen, pos.dx, pos.dy);
      },
      child: child,
    );
  }
}
