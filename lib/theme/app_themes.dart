import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

/// Paletas profesionales: Corporate Light, Industrial Dark, Ops Neon, Cyberpunk.
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

  static final AccentColor _opsNeon = AccentColor.swatch({
    'darkest': const Color(0xFF006064),
    'darker': const Color(0xFF007A86),
    'dark': const Color(0xFF00A3B5),
    'normal': const Color(0xFF00C7D8),
    'light': const Color(0xFF3DD9E5),
    'lighter': const Color(0xFF74E5EE),
    'lightest': const Color(0xFFB6F3F6),
  });

  /// CORPORATE LIGHT - clean neutral dashboard.
  static final FluentThemeData corporateLightTheme = FluentThemeData(
    brightness: Brightness.light,
    accentColor: _corporateBlue,
    scaffoldBackgroundColor: const Color(0xFFF4F6FB),
    cardColor: const Color(0xFFFFFFFF),
    micaBackgroundColor: const Color(0xFFE9EEF8),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFF202838)),
      bodyStrong: TextStyle(
        color: Color(0xFF111827),
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: Color(0xFF111827)),
      title: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w700),
      subtitle: TextStyle(color: Color(0xFF334155)),
      caption: TextStyle(color: Color(0xFF64748B)),
    ),
    iconTheme: const IconThemeData(color: Color(0xFF0F172A), size: 18.0),
    buttonTheme: ButtonThemeData(
      defaultButtonStyle: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.isDisabled) return const Color(0xFF94A3B8);
          return const Color(0xFF0F172A);
        }),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      filledButtonStyle: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.isDisabled) return const Color(0xFFCBD5E1);
          return const Color(0xFFFFFFFF);
        }),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
  );

  /// INDUSTRIAL DARK - robust operations theme with warm accents.
  static final FluentThemeData industrialDarkTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: _industrialOrange,
    scaffoldBackgroundColor: const Color(0xFF171A20),
    cardColor: const Color(0xFF212630),
    micaBackgroundColor: const Color(0xFF1C212B),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFFE4E8EF)),
      bodyStrong: TextStyle(
        color: Color(0xFFF8FAFC),
        fontWeight: FontWeight.bold,
      ),
      bodyLarge: TextStyle(color: Color(0xFFF1F5F9)),
      title: TextStyle(color: Color(0xFFF1F5F9), fontWeight: FontWeight.w700),
      subtitle: TextStyle(color: Color(0xFFCBD5E1)),
      caption: TextStyle(color: Color(0xFF94A3B8)),
    ),
    buttonTheme: ButtonThemeData(
      defaultButtonStyle: ButtonStyle(
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      filledButtonStyle: ButtonStyle(
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
  );

  /// OPS NEON DASHBOARD (replaces old high contrast mode).
  /// Dark gradient-like base + cyan/purple accents inspired by SaaS dashboards.
  static final FluentThemeData highContrastTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: _opsNeon,
    scaffoldBackgroundColor: const Color(0xFF131826),
    cardColor: const Color(0xFF1A2233),
    micaBackgroundColor: const Color(0xFF161E2F),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFFD9E2F2)),
      bodyStrong: TextStyle(
        color: Color(0xFFF8FAFC),
        fontWeight: FontWeight.bold,
      ),
      bodyLarge: TextStyle(color: Color(0xFFE2E8F0)),
      title: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.w700),
      subtitle: TextStyle(color: Color(0xFFC7D2E4)),
      caption: TextStyle(color: Color(0xFF94A3B8)),
    ),
    buttonTheme: ButtonThemeData(
      defaultButtonStyle: ButtonStyle(
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      filledButtonStyle: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(const Color(0xFF00C7D8)),
        foregroundColor: WidgetStateProperty.all(const Color(0xFF04111A)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
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
        return 'Ops Neon';
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
