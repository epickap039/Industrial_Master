import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';

import 'ayudas_menu_screen.dart';

/// Contenedor con [Navigator] interno para el flujo Ayudas (menú → categoría → visor).
class AyudasVisualesNav extends StatelessWidget {
  const AyudasVisualesNav({super.key, required this.canUpload});

  final bool canUpload;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (RouteSettings settings) {
        return material.MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => AyudasMenuScreen(canUpload: canUpload),
        );
      },
    );
  }
}
