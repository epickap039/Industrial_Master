import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Paletas profesionales: Corporate Light, Industrial Dark, Alto contraste, Cyberpunk.
enum AppThemeMode {
  corporateLight,
  industrialDark,
  highContrast,
  cyberpunk,
}

final appTheme = ThemeProvider();

class ThemeProvider extends ChangeNotifier {
  AppThemeMode _currentMode = AppThemeMode.industrialDark;

  AppThemeMode get currentMode => _currentMode;

  ThemeProvider() {
    _loadTheme();
  }

  /// Migra valores guardados con el enum antiguo (light, dark, apple, etc.).
  static AppThemeMode _migrateFromString(String? saved) {
    if (saved == null) return AppThemeMode.industrialDark;
    const legacy = <String, AppThemeMode>{
      'AppThemeMode.light': AppThemeMode.corporateLight,
      'AppThemeMode.dark': AppThemeMode.industrialDark,
      'AppThemeMode.apple': AppThemeMode.corporateLight,
      'AppThemeMode.platzi': AppThemeMode.industrialDark,
      'AppThemeMode.azure': AppThemeMode.corporateLight,
      'AppThemeMode.pastels': AppThemeMode.corporateLight,
      'AppThemeMode.cyberpunk': AppThemeMode.cyberpunk,
      'AppThemeMode.highContrast': AppThemeMode.highContrast,
      'AppThemeMode.corporateLight': AppThemeMode.corporateLight,
      'AppThemeMode.industrialDark': AppThemeMode.industrialDark,
    };
    final mapped = legacy[saved];
    if (mapped != null) return mapped;
    for (final m in AppThemeMode.values) {
      if (saved.endsWith(m.name)) return m;
    }
    return AppThemeMode.industrialDark;
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString('theme_mode');

    if (savedMode == null) {
      final isDark = prefs.getBool('isDarkMode') ?? true;
      _currentMode =
          isDark ? AppThemeMode.industrialDark : AppThemeMode.corporateLight;
    } else {
      _currentMode = _migrateFromString(savedMode);
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
      case AppThemeMode.corporateLight:
        return AppThemes.corporateLightTheme;
      case AppThemeMode.highContrast:
        return AppThemes.highContrastTheme;
      case AppThemeMode.cyberpunk:
        return AppThemes.cyberpunkTheme;
      case AppThemeMode.industrialDark:
        return AppThemes.industrialDarkTheme;
    }
  }
}

class AppThemes {
  static final AccentColor _corporateBlue = AccentColor.swatch({
    'darkest': const Color(0xFF0D47A1),
    'darker': const Color(0xFF1565C0),
    'dark': const Color(0xFF1976D2),
    'normal': const Color(0xFF1E88E5),
    'light': const Color(0xFF42A5F5),
    'lighter': const Color(0xFF64B5F6),
    'lightest': const Color(0xFF90CAF9),
  });

  static final AccentColor _industrialOrange = AccentColor.swatch({
    'darkest': const Color(0xFFE65100),
    'darker': const Color(0xFFEF6C00),
    'dark': const Color(0xFFF57C00),
    'normal': const Color(0xFFFF8C00),
    'light': const Color(0xFFFFA726),
    'lighter': const Color(0xFFFFB74D),
    'lightest': const Color(0xFFFFCC80),
  });

  static final AccentColor _highContrastYellow = AccentColor.swatch({
    'darkest': const Color(0xFFF9A825),
    'darker': const Color(0xFFFBC02D),
    'dark': const Color(0xFFFFD600),
    'normal': const Color(0xFFFFEB3B),
    'light': const Color(0xFFFFF176),
    'lighter': const Color(0xFFFFF59D),
    'lightest': const Color(0xFFFFF9C4),
  });

  /// CORPORATE LIGHT — fondo gris muy claro, acento azul oscuro, tipografía oscura (sin negro puro).
  static final FluentThemeData corporateLightTheme = FluentThemeData(
    brightness: Brightness.light,
    accentColor: _corporateBlue,
    scaffoldBackgroundColor: const Color(0xFFF3F3F3),
    cardColor: const Color(0xFFFAFAFA),
    micaBackgroundColor: const Color(0xFFE8E8E8),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFF242424)),
      bodyStrong: TextStyle(
        color: Color(0xFF1A1A1A),
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: Color(0xFF1A1A1A)),
      title: TextStyle(
        color: Color(0xFF383838),
        fontWeight: FontWeight.w600,
      ),
      subtitle: TextStyle(color: Color(0xFF37474F)),
      caption: TextStyle(color: Color(0xFF546E7A)),
    ),
  );

  /// INDUSTRIAL DARK — carbón, acento naranja, tipografía gris clara.
  static final FluentThemeData industrialDarkTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: _industrialOrange,
    scaffoldBackgroundColor: const Color(0xFF1E1E1E),
    cardColor: const Color(0xFF2A2A2A),
    micaBackgroundColor: const Color(0xFF252525),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFFE8E8E8)),
      bodyStrong: TextStyle(
        color: Color(0xFFF5F5F5),
        fontWeight: FontWeight.bold,
      ),
      bodyLarge: TextStyle(color: Color(0xFFF0F0F0)),
      title: TextStyle(
        color: Color(0xFFE8E8E8),
        fontWeight: FontWeight.w600,
      ),
      subtitle: TextStyle(color: Color(0xFFCCCCCC)),
      caption: TextStyle(color: Color(0xFFB0B0B0)),
    ),
  );

  /// HIGH CONTRAST (shop floor) — negro puro, acento amarillo, textos claros.
  static final FluentThemeData highContrastTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: _highContrastYellow,
    scaffoldBackgroundColor: const Color(0xFF000000),
    cardColor: const Color(0xFF121212),
    micaBackgroundColor: const Color(0xFF0A0A0A),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFFFFFFFF)),
      bodyStrong: TextStyle(
        color: Color(0xFFFFFFFF),
        fontWeight: FontWeight.bold,
      ),
      bodyLarge: TextStyle(color: Color(0xFFFFFFFF)),
      title: TextStyle(
        color: Color(0xFFFFFFFF),
        fontWeight: FontWeight.w600,
      ),
      subtitle: TextStyle(color: Color(0xFFFFFFFF)),
      caption: TextStyle(color: Color(0xFFE0E0E0)),
    ),
  );

  /// CYBERPUNK — se conserva la estética existente.
  static final FluentThemeData cyberpunkTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: Colors.teal,
    scaffoldBackgroundColor: const Color(0xFF050505),
    cardColor: const Color(0xFF111111),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFF00FFCC), fontFamily: 'Consolas'),
      title: TextStyle(
        color: Color(0xFF00FFCC),
        fontWeight: FontWeight.bold,
        fontFamily: 'Consolas',
      ),
      subtitle: TextStyle(color: Color(0xFF00FFCC), fontFamily: 'Consolas'),
    ),
    buttonTheme: ButtonThemeData(
      defaultButtonStyle: ButtonStyle(
        shape: ButtonState.all(
          BeveledRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: const BorderSide(color: Color(0xFF00FFCC)),
          ),
        ),
        elevation: ButtonState.all(0),
      ),
      filledButtonStyle: ButtonStyle(
        shape: ButtonState.all(
          BeveledRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: const BorderSide(color: Color(0xFF00FFCC)),
          ),
        ),
        elevation: ButtonState.all(0),
      ),
    ),
  );
}

/// Etiquetas para el selector de tema (footer NavigationView).
extension AppThemeModeLabel on AppThemeMode {
  String get displayLabel {
    switch (this) {
      case AppThemeMode.corporateLight:
        return 'Corporate Light';
      case AppThemeMode.industrialDark:
        return 'Industrial Dark';
      case AppThemeMode.highContrast:
        return 'Alto contraste';
      case AppThemeMode.cyberpunk:
        return 'Cyberpunk';
    }
  }
}

/// Mismo diálogo que el pie del [NavigationView] en [main.dart], reutilizable
/// desde pantallas sin menú lateral (p. ej. Gestor BOM a pantalla completa).
void showAppThemePickerDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (dialogCtx) {
      return ListenableBuilder(
        listenable: appTheme,
        builder: (_, __) {
          return ContentDialog(
            title: const Text('Tema visual'),
            content: SizedBox(
              width: 320,
              child: ComboBox<AppThemeMode>(
                value: appTheme.currentMode,
                items: AppThemeMode.values
                    .map(
                      (mode) => ComboBoxItem<AppThemeMode>(
                        value: mode,
                        child: Text(mode.displayLabel),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) appTheme.setTheme(v);
                },
              ),
            ),
            actions: [
              Button(
                child: const Text('Cerrar'),
                onPressed: () => Navigator.pop(dialogCtx),
              ),
            ],
          );
        },
      );
    },
  );
}
