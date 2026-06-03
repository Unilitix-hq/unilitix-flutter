import 'package:flutter/material.dart';
import 'package:unilitix/unilitix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Unilitix.init('YOUR_API_KEY', config: const UnilitixConfig(apiKey: 'YOUR_API_KEY', debug: true));
  Unilitix.runApp(const UnilitixWidget(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [Unilitix.observer],
      home: const UnilitixGestureDetector(child: HomeScreen()),
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
          ],
        ),
      ),
    );
  }
}
