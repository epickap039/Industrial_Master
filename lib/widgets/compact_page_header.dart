import 'package:fluent_ui/fluent_ui.dart';
import '../theme/ui_tokens.dart';

/// Misma función que [PageHeader] de fluent_ui, con padding total controlable.
/// El [PageHeader] original fija `bottom: 18` y solo permite `padding` horizontal (double).
class CompactPageHeader extends StatelessWidget {
  const CompactPageHeader({
    super.key,
    this.leading,
    this.title,
    this.commandBar,
    this.padding = const EdgeInsets.fromLTRB(
      UiTokens.pageHPadding,
      8,
      UiTokens.pageHPadding,
      10,
    ),
    this.applyTitleTypography = true,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? commandBar;
  final EdgeInsets padding;

  /// Si es false, no se aplica [Typography.title] al área del título (útil cuando el
  /// título es una fila con controles: evita inflar altura y espaciados del resto).
  final bool applyTitleTypography;

  /// Alineación vertical de la fila principal (p. ej. [CrossAxisAlignment.center] con buscador).
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final titleStyle = theme.typography.title;
    final titleChild = title ?? const SizedBox.shrink();
    final titleSlot = applyTitleTypography
        ? DefaultTextStyle.merge(
            style: titleStyle,
            child: titleChild,
          )
        : titleChild;

    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: crossAxisAlignment,
        children: [
          if (leading != null) leading!,
          Expanded(
            child: titleSlot,
          ),
          if (commandBar != null) ...[
            const SizedBox(width: 12),
            Flexible(
              fit: FlexFit.loose,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 160),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: commandBar!,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
