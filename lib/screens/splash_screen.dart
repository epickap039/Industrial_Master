import 'package:fluent_ui/fluent_ui.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigateToNext();
  }

  Future<void> _navigateToNext() async {
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    final hasToken = (prefs.getString('access_token') ?? '').trim().isNotEmpty;
    // Sesión activa hasta que el usuario pulse "Cerrar sesión" (sin caducidad por días).
    final actuallyLoggedIn = isLoggedIn && hasToken;

    Timer(const Duration(milliseconds: 3000), () {
      if (mounted) {
        Navigator.pushReplacementNamed(context, actuallyLoggedIn ? '/main' : '/login');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0A),
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 1500),
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'INGENIERÍA JAES',
                    style: FluentTheme.of(context).typography.title?.copyWith(
                          fontSize: 48,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 4,
                          decoration: TextDecoration.none,
                          color: FluentTheme.of(context).typography.body?.color,
                        ) ??
                        const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 4,
                          decoration: TextDecoration.none,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    height: 2,
                    width: 100 * value,
                    color: Colors.blue.withValues(alpha: 0.8),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
