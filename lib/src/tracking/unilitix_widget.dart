import 'package:flutter/widgets.dart';

import '../core/sdk_scope.dart';

/// Wrap your app content with [UnilitixWidget] to enable session replay and
/// automatic tap tracking. Place it in [MaterialApp.builder] so screenshots
/// capture fully rendered content.
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [Unilitix.observer],
///   builder: (context, child) => UnilitixWidget(child: child!),
/// )
/// ```
class UnilitixWidget extends StatefulWidget {
  final Widget child;
  const UnilitixWidget({super.key, required this.child});

  @override
  State<UnilitixWidget> createState() => _UnilitixWidgetState();
}

class _UnilitixWidgetState extends State<UnilitixWidget> {
  bool _observerRegistered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_observerRegistered) {
      final navigator = Navigator.maybeOf(context);
      if (navigator != null) {
        SdkScope.onObserverConnected?.call();
        _observerRegistered = true;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    SdkScope.widgetHandlesTaps = true;
  }

  @override
  void dispose() {
    SdkScope.widgetHandlesTaps = false;
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent e) {
    final pos = e.position;
    SdkScope.onTap?.call(SdkScope.currentScreen ?? 'unknown', pos.dx, pos.dy);
  }

  @override
  Widget build(BuildContext context) {
    // A raw pointer listener records taps for `autoTrackTaps` without taking
    // part in gesture arenas, so it never steals a tap, drag or long-press
    // from the app. Wrapping in UnilitixGestureDetector is no longer needed.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      child: RepaintBoundary(
        key: SdkScope.repaintKey,
        child: widget.child,
      ),
    );
  }
}
