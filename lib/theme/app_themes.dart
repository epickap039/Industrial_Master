import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode { light, dark, cyberpunk }

final appTheme = ThemeProvider();

class ThemeProvider extends ChangeNotifier {
  AppThemeMode _currentMode = AppThemeMode.dark;
  
  AppThemeMode get currentMode => _currentMode;
  
  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString('theme_mode');
    
    // Migración del modo antiguo 'isDarkMode' si existe
    if (savedMode == null) {
      final isDark = prefs.getBool('isDarkMode') ?? true;
      _currentMode = isDark ? AppThemeMode.dark : AppThemeMode.light;
    } else {
      _currentMode = AppThemeMode.values.firstWhere(
        (e) => e.toString() == savedMode,
        orElse: () => AppThemeMode.dark
      );
    }
    notifyListeners();
  }

  Future<void> setTheme(AppThemeMode mode) async {
    _currentMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.toString());
  }

  FluentThemeData get currentTheme {
    switch (_currentMode) {
      case AppThemeMode.light:
        return AppThemes.lightTheme;
      case AppThemeMode.cyberpunk:
        return AppThemes.cyberpunkTheme;
      case AppThemeMode.dark:
      default:
        return AppThemes.darkTheme;
    }
  }
}

class AppThemes {
  static final FluentThemeData darkTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: Colors.blue,
    scaffoldBackgroundColor: const Color(0xFF202020),
    cardColor: const Color(0xFF2D2D2D),
  );

  static final FluentThemeData lightTheme = FluentThemeData(
    brightness: Brightness.light,
    accentColor: Colors.blue,
    scaffoldBackgroundColor: const Color(0xFFF3F3F3),
    cardColor: Colors.white,
  );

  static final FluentThemeData cyberpunkTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: Colors.teal, // Cyan-ish
    scaffoldBackgroundColor: const Color(0xFF050505),
    cardColor: const Color(0xFF111111),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFF00FFCC), fontFamily: 'Consolas'),
      title: TextStyle(color: Color(0xFF00FFCC), fontWeight: FontWeight.bold),
      subtitle: TextStyle(color: Color(0xFF00FFCC)),
    ),
  );
}
