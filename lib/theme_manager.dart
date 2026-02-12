import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager extends ChangeNotifier {
  static const _themeKey = 'is_dark_mode';
  bool _isDarkMode = true;

  ThemeManager() {
    _loadTheme();
  }

  bool get isDarkMode => _isDarkMode;

  ThemeMode get themeMode => _isDarkMode ? ThemeMode.dark : ThemeMode.light;

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    _saveTheme();
    notifyListeners();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_themeKey) ?? true;
    notifyListeners();
  }

  Future<void> _saveTheme() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, _isDarkMode);
  }

  // ENTERPRISE LIGHT THEME (v11.0)
  FluentThemeData get lightTheme => FluentThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF4F5F7), // Gris Humo
        cardColor: Colors.white,
        accentColor: Colors.blue,
        typography: Typography.raw(
          body: const TextStyle(color: Color(0xFF475569)), // Slate 600
          title: const TextStyle(color: Color(0xFF1E293B), fontWeight: FontWeight.bold), // Slate 800
          subtitle: const TextStyle(color: Color(0xFF334155)), // Slate 700
          caption: const TextStyle(color: Color(0xFF64748B)), // Slate 500
        ),
      );

  // ENTERPRISE DARK THEME (v11.0)
  FluentThemeData get darkTheme => FluentThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111827), // Gris Carbón Profundo
        cardColor: const Color(0xFF1F2937), // Gris Grafito
        accentColor: Colors.blue, // Fallback safe color
        typography: Typography.raw(
          body: const TextStyle(color: Color(0xFF9CA3AF)), // Gris Claro (Cool Gray 400)
          title: const TextStyle(color: Color(0xFFF3F4F6), fontWeight: FontWeight.bold), // Blanco Humo
          subtitle: const TextStyle(color: Color(0xFFE5E7EB)), // Cool Gray 200
          caption: const TextStyle(color: Color(0xFF9CA3AF)), // Cool Gray 400
        ),
      );
}

final themeManager = ThemeManager();
