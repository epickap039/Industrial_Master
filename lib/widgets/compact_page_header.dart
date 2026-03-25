import 'package:fluent_ui/fluent_ui.dart';

/// Misma función que [PageHeader] de fluent_ui, con padding total controlable.
/// El [PageHeader] original fija `bottom: 18` y solo permite `padding` horizontal (double).
class CompactPageHeader extends StatelessWidget {
  const CompactPageHeader({
    super.key,
    this.leading,
    this.title,
    this.commandBar,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
  });

  final Widget? leading;
  final Widget? title;
  final Widget? commandBar;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final titleStyle = theme.typography.title;

    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) leading!,
          Expanded(
            child: DefaultTextStyle.merge(
              style: titleStyle,
              child: title ?? const SizedBox.shrink(),
            ),
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
