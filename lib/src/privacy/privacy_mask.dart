import 'package:flutter/widgets.dart';

/// Wrap any widget with [UnilitixPrivate] to exclude it from
/// snapshot capture and screenshot masking.
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
