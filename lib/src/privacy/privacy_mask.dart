import 'package:flutter/widgets.dart';

/// Excludes this widget subtree from wireframe snapshot JSON capture.
///
/// Note: [UnilitixPrivate] does NOT mask pixel screenshots (PixelCopy/toImage path).
/// To prevent sensitive content appearing in screenshots, use `captureScreenshots: false`
/// in [UnilitixConfig] or implement OS-level screenshot prevention.
///
/// ```dart
/// UnilitixPrivate(
///   child: TextField(controller: _passwordController),
/// )
/// ```
class UnilitixPrivate extends StatelessWidget {
  final Widget child;

  const UnilitixPrivate({required this.child, super.key});

  @override
  Widget build(BuildContext context) => child;
}
