import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode { light, dark, cyberpunk, apple, platzi, azure, pastels }

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
      case AppThemeMode.apple:
        return AppThemes.appleTheme;
      case AppThemeMode.platzi:
        return AppThemes.platziTheme;
      case AppThemeMode.azure:
        return AppThemes.azureTheme;
      case AppThemeMode.pastels:
        return AppThemes.pastelsTheme;
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

  static final FluentThemeData appleTheme = FluentThemeData(
    brightness: Brightness.light,
    accentColor: Colors.blue, // iOS/macOS Default Accent
    scaffoldBackgroundColor: const Color(0xFFF9F9F9), // Ultra suave
    cardColor: const Color(0xFFFFFFFF), // Blanco translúcido en concepto
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFF333333)), // Sin negros duros
      title: TextStyle(color: Color(0xFF111111), fontWeight: FontWeight.w600),
    ),
  );

  static final FluentThemeData platziTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: Colors.green, // Aproximación a #98CA3F en Fluent "Colors.green" (AccentColor)
    scaffoldBackgroundColor: const Color(0xFF121F3D),
    cardColor: const Color(0xFF192A52),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFFF0F0F0)),
      title: TextStyle(color: Color(0xFFFFFFFF), fontWeight: FontWeight.bold),
    ),
  );

  static final FluentThemeData azureTheme = FluentThemeData(
    brightness: Brightness.light,
    accentColor: Colors.blue,
    scaffoldBackgroundColor: const Color(0xFFE3F2FD), // Celeste/Hielo
    cardColor: const Color(0xFFFFFFFF),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFF0D47A1)), // Azul Marino
      title: TextStyle(color: Color(0xFF0D47A1), fontWeight: FontWeight.bold),
      subtitle: TextStyle(color: Color(0xFF1565C0)),
    ),
  );

  static final FluentThemeData pastelsTheme = FluentThemeData(
    brightness: Brightness.light,
    accentColor: Colors.purple, // Lavanda
    scaffoldBackgroundColor: const Color(0xFFF3E5F5), // Lavanda muy suave
    cardColor: const Color(0xFFFAFAFA),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFF4A148C)),
      title: TextStyle(color: Color(0xFF880E4F), fontWeight: FontWeight.bold), // Acentos hacia rosa
    ),
  );
}
