import 'package:flutter/material.dart';
import 'package:unilitix/unilitix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Unilitix.init(
    'your_api_key_here',
    config: const UnilitixConfig(debug: true),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unilitix Example',
      navigatorObservers: [Unilitix.observer],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF5A623),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
        '/profile': (_) => const ProfileScreen(),
        '/settings': (_) => const SettingsScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unilitix Demo'),
        backgroundColor: const Color(0xFFF5A623),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Unilitix SDK Demo',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'SDK initialized: ${Unilitix.isInitialized}',
              style: const TextStyle(color: Colors.green),
            ),
            const SizedBox(height: 32),
            _DemoButton(
              label: 'Track event',
              color: const Color(0xFFF5A623),
              onTap: () => Unilitix.track(
                'demo_button_tapped',
                {'screen': 'home', 'button': 'track_event'},
              ),
            ),
            const SizedBox(height: 12),
            _DemoButton(
              label: 'Identify user',
              color: const Color(0xFF4F8EF7),
              onTap: () => Unilitix.identify(
                'demo_user_123',
                {
                  'name': 'Demo User',
                  'plan': 'pro',
                  'country': 'Nigeria',
                },
              ),
            ),
            const SizedBox(height: 12),
            _DemoButton(
              label: 'Navigate to Profile',
              color: const Color(0xFF2DC98A),
              onTap: () => Navigator.pushNamed(context, '/profile'),
            ),
            const SizedBox(height: 12),
            _DemoButton(
              label: 'Flush events',
              color: const Color(0xFFA855F7),
              onTap: () async {
                await Unilitix.flush();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('✓ Events flushed')),
                  );
                }
              },
            ),
            const SizedBox(height: 12),
            _DemoButton(
              label: 'Reset (logout)',
              color: const Color(0xFF64748B),
              onTap: () => Unilitix.reset(),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Profile Screen'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/settings'),
              child: const Text('Go to Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const Center(child: Text('Settings Screen')),
    );
  }
}

class _DemoButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _DemoButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
