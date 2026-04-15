import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';

import 'ayudas_menu_screen.dart';

/// Contenedor con [Navigator] interno para el flujo Ayudas (menú → categoría → visor).
class AyudasVisualesNav extends StatelessWidget {
  const AyudasVisualesNav({
    super.key,
    required this.canUpload,
    this.canEditCategoryImage = false,
    this.allowRevisionHistory = true,
    this.allowCrossDocumentCompare = true,
  });

  final bool canUpload;
  final bool canEditCategoryImage;
  final bool allowRevisionHistory;
  final bool allowCrossDocumentCompare;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (RouteSettings settings) {
        return material.MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => AyudasMenuScreen(
            canUpload: canUpload,
            canEditCategoryImage: canEditCategoryImage,
            allowRevisionHistory: allowRevisionHistory,
            allowCrossDocumentCompare: allowCrossDocumentCompare,
          ),
        );
      },
    );
  }
}
