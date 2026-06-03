import 'package:flutter/widgets.dart';

import '../../unilitix.dart';

/// Wrap your app's root widget with [UnilitixWidget] to enable session replay.
/// Place it in [Unilitix.runApp], wrapping your [MaterialApp] or root widget.
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Unilitix.init('YOUR_API_KEY');
///   Unilitix.runApp(
///     UnilitixWidget(child: MyApp()),
///   );
/// }
///
/// class MyApp extends StatelessWidget {
///   @override
///   Widget build(BuildContext context) {
///     return MaterialApp(
///       navigatorObservers: [Unilitix.observer],
///       home: const HomeScreen(),
///     );
///   }
/// }
/// ```
class UnilitixWidget extends StatelessWidget {
  final Widget child;
  const UnilitixWidget({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: Unilitix.repaintKey,
      child: child,
    );
  }
}
