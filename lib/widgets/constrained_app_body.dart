import 'package:flutter/widgets.dart';

/// Centra el contenido y limita el ancho en monitores ultra anchos (pane compacto).
class ConstrainedAppBody extends StatelessWidget {
  const ConstrainedAppBody({super.key, required this.child});

  final Widget child;

  static const double maxContentWidth = 1400;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final useW = w > maxContentWidth ? maxContentWidth : w;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: useW,
            height: constraints.maxHeight,
            child: child,
          ),
        );
      },
    );
  }
}
