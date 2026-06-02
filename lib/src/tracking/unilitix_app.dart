import 'package:flutter/widgets.dart';

/// Deprecated. Use [UnilitixMaterialApp] instead for automatic screen tracking.
///
/// Previously this provided an [InheritedWidget] scope for the observer, but
/// it did not actually inject the observer into [Navigator.observers].
/// [UnilitixMaterialApp] is the correct zero-config replacement.
@Deprecated('Use UnilitixMaterialApp instead for automatic screen tracking')
class UnilitixApp extends StatelessWidget {
  final Widget child;
  const UnilitixApp({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
