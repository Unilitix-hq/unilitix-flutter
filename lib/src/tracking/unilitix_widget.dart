import 'package:flutter/widgets.dart';

import '../core/sdk_scope.dart';

/// Wrap your app content with [UnilitixWidget] to enable session replay.
/// Place it in [MaterialApp.builder] so screenshots capture fully rendered content.
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
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: SdkScope.repaintKey,
      child: widget.child,
    );
  }
}
