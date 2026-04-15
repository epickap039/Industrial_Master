import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

/// Paletas profesionales: Corporate Light, Industrial Dark, Ops Neon, Cyberpunk.
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
      // Temas retirados: migran a Corporate Light.
      'AppThemeMode.roseLight': AppThemeMode.corporateLight,
      'AppThemeMode.skyLight': AppThemeMode.corporateLight,
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

  static final AccentColor _roseAccent = AccentColor.swatch({
    'darkest': const Color(0xFF8A3054),
    'darker': const Color(0xFFA33F66),
    'dark': const Color(0xFFBC4E78),
    'normal': const Color(0xFFD66690),
    'light': const Color(0xFFE289AB),
    'lighter': const Color(0xFFEDAFCA),
    'lightest': const Color(0xFFF6D4E3),
  });

  static final AccentColor _skyAccent = AccentColor.swatch({
    'darkest': const Color(0xFF1E5D8A),
    'darker': const Color(0xFF2A6EA0),
    'dark': const Color(0xFF377FB7),
    'normal': const Color(0xFF4B97CF),
    'light': const Color(0xFF6DAFD9),
    'lighter': const Color(0xFF9BCAE7),
    'lightest': const Color(0xFFCFE6F4),
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

  /// CYBERPUNK (refinado): estilo oscuro sin deformar tipografías ni botones.
  static final FluentThemeData cyberpunkTheme = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: AccentColor.swatch(const <String, Color>{
      'darkest': Color(0xFF006064),
      'darker': Color(0xFF00838F),
      'dark': Color(0xFF00ACC1),
      'normal': Color(0xFF00E5FF),
      'light': Color(0xFF67E8F9),
      'lighter': Color(0xFFA5F3FC),
      'lightest': Color(0xFFCCFBF1),
    }),
    scaffoldBackgroundColor: const Color(0xFF090B13),
    cardColor: const Color(0xFF151927),
    micaBackgroundColor: const Color(0xFF0E1424),
    typography: const Typography.raw(
      body: TextStyle(color: Color(0xFFE2E8F0)),
      bodyStrong: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.w700),
      bodyLarge: TextStyle(color: Color(0xFFF1F5F9)),
      title: TextStyle(
        color: Color(0xFFF8FAFC),
        fontWeight: FontWeight.w700,
      ),
      subtitle: TextStyle(color: Color(0xFFCBD5E1)),
      caption: TextStyle(color: Color(0xFF94A3B8)),
    ),
    buttonTheme: ButtonThemeData(
      defaultButtonStyle: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(const Color(0xFFB2F5EA)),
        backgroundColor: WidgetStateProperty.all(const Color(0xFF111827)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
          ),
        ),
      ),
      filledButtonStyle: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(const Color(0xFFE11D8A)),
        foregroundColor: WidgetStateProperty.all(const Color(0xFFF8FAFC)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFFF472B6), width: 1),
          ),
        ),
      ),
    ),
  );
}

// ============================================================================
// MEJORA INTEGRAL v15.5: Paleta de colores para asignación de usuarios
// ============================================================================

class UserColorPalette {
  /// 18 colores para asignación de usuarios (incluye gris temporal multiuso).
  static const List<Color> userColors = [
    Color(0xFF7F7F7F), // Gris temporal
    Color(0xFF42A5F5), // Azul eléctrico
    Color(0xFF64B5F6), // Azul cielo intenso
    Color(0xFF5C6BC0), // Índigo
    Color(0xFF7E57C2), // Violeta
    Color(0xFF9575CD), // Lavanda fuerte
    Color(0xFFAB47BC), // Magenta violeta
    Color(0xFFBA68C8), // Lila neón
    Color(0xFF26C6DA), // Cian intenso
    Color(0xFF00ACC1), // Turquesa profundo
    Color(0xFF29B6F6), // Azul agua
    Color(0xFF4FC3F7), // Celeste frío
    Color(0xFFFF8A65), // Coral suave
    Color(0xFFFF7043), // Coral intenso
    Color(0xFFF06292), // Rosa frambuesa
    Color(0xFF7986CB), // Índigo suave
    Color(0xFF4DD0E1), // Turquesa claro
    Color(0xFF81D4FA), // Azul hielo
  ];

  /// Códigos hexadecimales correspondientes para envío a API
  static const List<String> userColorsHex = [
    '#7F7F7F', // Gris temporal
    '#42A5F5', // Azul eléctrico
    '#64B5F6', // Azul cielo intenso
    '#5C6BC0', // Índigo
    '#7E57C2', // Violeta
    '#9575CD', // Lavanda fuerte
    '#AB47BC', // Magenta violeta
    '#BA68C8', // Lila neón
    '#26C6DA', // Cian intenso
    '#00ACC1', // Turquesa profundo
    '#29B6F6', // Azul agua
    '#4FC3F7', // Celeste frío
    '#FF8A65', // Coral suave
    '#FF7043', // Coral intenso
    '#F06292', // Rosa frambuesa
    '#7986CB', // Índigo suave
    '#4DD0E1', // Turquesa claro
    '#81D4FA', // Azul hielo
  ];

  /// Nombres amigables para cada color
  static const List<String> userColorNames = [
    'Gris temporal',
    'Azul eléctrico',
    'Azul cielo intenso',
    'Índigo',
    'Violeta',
    'Lavanda fuerte',
    'Magenta violeta',
    'Lila neón',
    'Cian intenso',
    'Turquesa profundo',
    'Azul agua',
    'Celeste frío',
    'Coral suave',
    'Coral intenso',
    'Rosa frambuesa',
    'Índigo suave',
    'Turquesa claro',
    'Azul hielo',
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
