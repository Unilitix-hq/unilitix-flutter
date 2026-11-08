import 'package:flutter/material.dart';
import 'package:unilitix/unilitix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pass the key at build time, never commit it:
  //   flutter run --dart-define=UNILITIX_API_KEY=<your key>
  const apiKey =
      String.fromEnvironment('UNILITIX_API_KEY', defaultValue: 'YOUR_API_KEY');
  await Unilitix.init(apiKey,
      config: const UnilitixConfig(apiKey: apiKey, debug: true));
  Unilitix.runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [Unilitix.observer],
      // Session replay and taps: wrap the app content, inside MaterialApp.
      builder: (context, child) => UnilitixWidget(child: child!),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unilitix Example'),
        backgroundColor: const Color(0xFFF5A623),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'SDK initialized: ${Unilitix.isInitialized}',
              style: const TextStyle(color: Colors.green),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () => Unilitix.track('button_tapped', {
                'button': 'Get Started',
                'screen': 'Home',
              }),
              child: const Text('Track Event'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => Unilitix.identify('demo_user_123', {
                'name': 'Ada Okafor',
                'plan': 'pro',
                'country': 'Nigeria',
              }),
              child: const Text('Identify User'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => Unilitix.reset(),
              child: const Text('Reset (logout)'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                try {
                  throw StateError('example handled error');
                } catch (e, st) {
                  Unilitix.captureException(e, stackTrace: st);
                }
              },
              child: const Text('Report handled error'),
            ),
            const SizedBox(height: 24),
            // Never in a screenshot or a wireframe.
            const UnilitixPrivate(child: Text('Balance: NGN 120,000')),
          ],
        ),
      ),
    );
  }
}
