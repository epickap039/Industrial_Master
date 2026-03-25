import 'package:fluent_ui/fluent_ui.dart';

/// Color de título de página sin acento (pizarra / gris claro según tema).
Color pageTitleForegroundColor(FluentThemeData theme) {
  switch (theme.brightness) {
    case Brightness.dark:
      return const Color(0xFFE8E8E8);
    case Brightness.light:
      return const Color(0xFF383838);
  }
}

/// Estilo para títulos grandes: usa el color de [Typography.title] del tema (neutro), no el acento.
TextStyle pageTitleTextStyle(BuildContext context, {double fontSize = 28}) {
  final theme = FluentTheme.of(context);
  final base = theme.typography.title;
  final color = base?.color ?? pageTitleForegroundColor(theme);
  if (base != null) {
    return base.copyWith(
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
    );
  }
  return TextStyle(
    fontSize: fontSize,
    fontWeight: FontWeight.w600,
    color: color,
  );
}
