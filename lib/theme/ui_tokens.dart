import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

/// Base visual tokens for compact and consistent UI.
class UiTokens {
  static const double pageHPadding = 20;
  static const double pageVPadding = 12;
  static const double sectionGap = 14;
  static const double cardRadius = 12;
  static const double cardPadding = 16;
  static const double controlHeight = 40;
}

EdgeInsets pagePadding() => const EdgeInsets.fromLTRB(
  UiTokens.pageHPadding,
  UiTokens.pageVPadding,
  UiTokens.pageHPadding,
  20,
);

/// Fondo del rail + [NavigationAppBar]. En modo oscuro, más oscuro que el
/// scaffold para un aspecto tipo “modo noche” clásico.
Color shellNavChromeBackground(FluentThemeData theme) {
  final base = theme.micaBackgroundColor;
  if (theme.brightness == Brightness.dark) {
    // Shell oscuro real: negro/azul marino profundo.
    final nearBlack = Color.alphaBlend(
      const Color(0xFF02060F).withValues(alpha: 0.72),
      base,
    );
    return Color.alphaBlend(
      const Color(0xFF0A1730).withValues(alpha: 0.28),
      nearBlack,
    );
  }
  return Color.alphaBlend(
    const Color(0xFF000000).withValues(alpha: 0.1),
    base,
  );
}

/// Token palette shared across operational screens.
class UiSurfacePalette {
  const UiSurfacePalette({
    required this.surfaceBase,
    required this.surfaceCard,
    required this.surfaceElevated,
    required this.borderSubtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.tableStripe,
    required this.actionInfo,
    required this.actionEdit,
    required this.actionLink,
    required this.actionCopy,
    required this.actionDanger,
  });

  final Color surfaceBase;
  final Color surfaceCard;
  final Color surfaceElevated;
  final Color borderSubtle;
  final Color textPrimary;
  final Color textSecondary;
  final Color tableStripe;
  final Color actionInfo;
  final Color actionEdit;
  final Color actionLink;
  final Color actionCopy;
  final Color actionDanger;
}

UiSurfacePalette uiSurfacePaletteOf(BuildContext context) {
  final theme = FluentTheme.of(context);
  final dark = theme.brightness == Brightness.dark;
  final body = theme.typography.body?.color ??
      (dark ? const Color(0xFFE5E7EB) : const Color(0xFF1F2937));
  final caption = theme.typography.caption?.color ??
      (dark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B));

  if (dark) {
    return UiSurfacePalette(
      surfaceBase: Color.alphaBlend(
        const Color(0xFF000000).withValues(alpha: 0.14),
        theme.scaffoldBackgroundColor,
      ),
      surfaceCard: Color.alphaBlend(
        const Color(0xFF000000).withValues(alpha: 0.16),
        theme.cardColor,
      ),
      surfaceElevated: Color.alphaBlend(
        const Color(0xFF000000).withValues(alpha: 0.08),
        theme.cardColor,
      ),
      borderSubtle: const Color(0xFF2D3543),
      textPrimary: body,
      textSecondary: caption,
      tableStripe: Colors.white.withValues(alpha: 0.025),
      actionInfo: theme.accentColor,
      actionEdit: const Color(0xFFFFB347),
      actionLink: const Color(0xFF2EC4B6),
      actionCopy: const Color(0xFFB388FF),
      actionDanger: const Color(0xFFFF6B6B),
    );
  }

  return UiSurfacePalette(
    surfaceBase: const Color(0xFFF2F5FA),
    surfaceCard: const Color(0xFFF8FAFD),
    surfaceElevated: const Color(0xFFFFFFFF),
    borderSubtle: const Color(0xFFD3DCE8),
    textPrimary: body,
    textSecondary: caption,
    tableStripe: const Color(0xFFF0F4F9),
    actionInfo: const Color(0xFF2563EB),
    actionEdit: const Color(0xFFB45309),
    actionLink: const Color(0xFF0F766E),
    actionCopy: const Color(0xFF6B21A8),
    actionDanger: const Color(0xFFB91C1C),
  );
}

BoxDecoration elevatedCardDecoration(FluentThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  final cardSurfaceA =
      dark ? theme.cardColor.withOpacity(0.94) : theme.cardColor;
  final cardSurfaceB =
      dark ? const Color(0xFF1E2A3D).withOpacity(0.46) : const Color(0xFFFFFFFF);
  return BoxDecoration(
    gradient:
        dark
            ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [cardSurfaceA, cardSurfaceB],
            )
            : null,
    color: dark ? null : theme.cardColor,
    borderRadius: BorderRadius.circular(UiTokens.cardRadius),
    // Dark mode: no bright border; rely on depth shadow.
    border:
        dark
            ? null
            : Border.all(
              color: theme.resources.controlStrokeColorDefault.withOpacity(0.9),
            ),
    boxShadow: [
      BoxShadow(
        color:
            dark
                ? material.Colors.black.withOpacity(0.35)
                : material.Colors.black.withOpacity(0.08),
        blurRadius: dark ? 20 : 10,
        offset: const Offset(0, 4),
      ),
    ],
  );
}

ButtonStyle roundedFilledButtonStyle() {
  return ButtonStyle(
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

/// Color for secondary/helper text in light and dark Fluent themes.
Color fluentSecondaryTextColor(BuildContext context) {
  final t = FluentTheme.of(context);
  return t.typography.caption?.color ?? t.resources.textFillColorSecondary;
}

/// Secondary/helper text style helper.
TextStyle fluentSecondaryTextStyle(
  BuildContext context, {
  double? fontSize,
  FontWeight? fontWeight,
  FontStyle? fontStyle,
  double? height,
}) {
  return TextStyle(
    color: fluentSecondaryTextColor(context),
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    height: height,
  );
}