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