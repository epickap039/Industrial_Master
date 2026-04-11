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
  if (theme.brightness == Brightness.dark) {
    // En oscuro: gris profundo para barra lateral + superior.
    return const Color(0xFF111827);
  }
  // En claro, mantener chrome oscuro para evitar apariencia lavada.
  return const Color(0xFF031226);
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

  final accent = theme.accentColor;
  final baseSurface = Color.alphaBlend(
    accent.withValues(alpha: 0.05),
    theme.scaffoldBackgroundColor,
  );
  final cardSurface = Color.alphaBlend(
    theme.micaBackgroundColor.withValues(alpha: 0.18),
    theme.cardColor,
  );
  final elevatedSurface = Color.alphaBlend(
    Colors.white.withValues(alpha: 0.72),
    theme.cardColor,
  );
  final stripe = Color.alphaBlend(
    accent.withValues(alpha: 0.08),
    cardSurface,
  );
  final border = Color.alphaBlend(
    accent.withValues(alpha: 0.22),
    theme.resources.controlStrokeColorDefault,
  );

  return UiSurfacePalette(
    surfaceBase: baseSurface,
    surfaceCard: cardSurface,
    surfaceElevated: elevatedSurface,
    borderSubtle: border,
    textPrimary: body,
    textSecondary: caption,
    tableStripe: stripe,
    actionInfo: accent,
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