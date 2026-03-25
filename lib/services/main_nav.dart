import 'package:flutter/widgets.dart';

/// Índice del panel **Importar Excel** (arbitraje de catálogo) en el
/// [NavigationPane] principal (rol distinto de QA). Alineado con Lobby/accesos.
const int kMainPaneImportarExcel = 6;

/// Navegación al shell principal ([NavigationView] en `main.dart`).
/// Las rutas apiladas con [Navigator.push] no heredan un `InheritedWidget`
/// del cuerpo del panel; por eso se usa un registro explícito.
class MainNav {
  MainNav._();

  static void Function(int index)? _goToPane;

  static void registerPaneNavigator(void Function(int index) fn) {
    _goToPane = fn;
  }

  static void goToPane(int index) => _goToPane?.call(index);

  /// Cierra overlays hasta la ruta raíz y luego selecciona el panel.
  static void goToPanePopOverlays(BuildContext context, int index) {
    final nav = Navigator.of(context, rootNavigator: true);
    nav.popUntil((route) => route.isFirst);
    _goToPane?.call(index);
  }
}
