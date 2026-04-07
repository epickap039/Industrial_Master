import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

/// Paletas profesionales: Corporate Light, Industrial Dark, Alto contraste, Cyberpunk.
enum AppThemeMode { corporateLight, industrialDark, highContrast, cyberpunk }

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
      title: TextStyle(color: Color(0xFF383838), fontWeight: FontWeight.w600),
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
      title: TextStyle(color: Color(0xFFE8E8E8), fontWeight: FontWeight.w600),
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
      title: TextStyle(color: Color(0xFFFFFFFF), fontWeight: FontWeight.w600),
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
        shape: WidgetStateProperty.all(
          BeveledRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: const BorderSide(color: Color(0xFF00FFCC)),
          ),
        ),
        elevation: WidgetStateProperty.all(0),
      ),
      filledButtonStyle: ButtonStyle(
        shape: WidgetStateProperty.all(
          BeveledRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: const BorderSide(color: Color(0xFF00FFCC)),
          ),
        ),
        elevation: WidgetStateProperty.all(0),
      ),
    ),
  );
}

// ============================================================================
// MEJORA INTEGRAL v15.5: Paleta de colores para asignación de usuarios
// ============================================================================

class UserColorPalette {
  /// 12 colores estándares WCAG AA compatible para asignación a usuarios.
  /// Cada color tiene contraste ≥ 4.5:1 contra backgrounds oscuros.
  static const List<Color> userColors = [
    Color(0xFFFF8C00), // Naranja (default)
    Color(0xFFFF6B6B), // Rojo vibrante
    Color(0xFF4ECDC4), // Teal
    Color(0xFF45B7D1), // Azul celeste
    Color(0xFF96CEB4), // Verde menta
    Color(0xFFFFFAED), // Blanco crema
    Color(0xFFEEAAED), // Magenta/Púrpura
    Color(0xFFDDA0DD), // Plumero
    Color(0xFFA4DE6C), // Verde lima
    Color(0xFF74B9FF), // Azul cielo
    Color(0xFFA29BFE), // Lavanda
    Color(0xFFF7B731), // Oro
  ];

  /// Códigos hexadecimales correspondientes para envío a API
  static const List<String> userColorsHex = [
    '#FF8C00', // Naranja (default)
    '#FF6B6B', // Rojo vibrante
    '#4ECDC4', // Teal
    '#45B7D1', // Azul celeste
    '#96CEB4', // Verde menta
    '#FFFFAED', // Blanco crema
    '#EEAAED', // Magenta/Púrpura
    '#DDA0DD', // Plumero
    '#A4DE6C', // Verde lima
    '#74B9FF', // Azul cielo
    '#A29BFE', // Lavanda
    '#F7B731', // Oro
  ];

  /// Nombres amigables para cada color
  static const List<String> userColorNames = [
    'Naranja (Default)',
    'Rojo Vibrante',
    'Teal',
    'Azul Celeste',
    'Verde Menta',
    'Blanco Crema',
    'Magenta',
    'Plumero',
    'Verde Lima',
    'Azul Cielo',
    'Lavanda',
    'Oro',
  ];

  /// Obtener color por índice
  static Color getColorByIndex(int index) {
    return userColors[index % userColors.length];
  }

  /// Obtener color por código hexadecimal
  static Color? getColorByHex(String hex) {
    try {
      final cleanHex = hex.replaceAll('#', '').toUpperCase();
      final index = userColorsHex.indexWhere(
        (h) => h.replaceAll('#', '') == cleanHex,
      );
      return index >= 0 ? userColors[index] : null;
    } catch (e) {
      return userColors[0]; // Fallback a naranja
    }
  }

  /// Obtener hexadecimal por índice
  static String getHexByIndex(int index) {
    return userColorsHex[index % userColorsHex.length];
  }

  /// Obtener nombre amigable por índice
  static String getNameByIndex(int index) {
    return userColorNames[index % userColorNames.length];
  }

  /// Encontrar índice más cercano por color
  static int getIndexByColor(Color color) {
    for (int i = 0; i < userColors.length; i++) {
      if (userColors[i].toARGB32() == color.toARGB32()) return i;
    }
    return 0; // Fallback a naranja
  }
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
  final isDark =
      material.Theme.of(context).brightness == material.Brightness.dark;
  final dialogBg = isDark ? const Color(0xFF000000) : material.Colors.white;
  material.showDialog(
    context: context,
    barrierColor: dialogBg,
    builder: (dialogCtx) {
      return material.SimpleDialog(
        title: const material.Text('Tema visual'),
        shape: material.RoundedRectangleBorder(
          borderRadius: material.BorderRadius.circular(20.0),
        ),
        backgroundColor: dialogBg,
        elevation: 0,
        children:
            AppThemeMode.values.map((mode) {
              return material.RadioListTile<AppThemeMode>(
                title: material.Text(mode.displayLabel),
                value: mode,
                groupValue: appTheme.currentMode,
                tileColor: dialogBg,
                selectedTileColor: dialogBg,
                onChanged: (value) {
                  if (value == null) return;
                  appTheme.setTheme(value);
                  Navigator.pop(dialogCtx);
                },
              );
            }).toList(),
      );
    },
  );
}
