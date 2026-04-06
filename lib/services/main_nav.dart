import 'package:flutter/widgets.dart';

/// Índices en [NavigationPane.effectiveItems] (solo [PaneItem]; sin headers ni [PaneItemAction]).
/// Flujo: Ingeniería → Gestión → Control → Administración.
///
/// Ver `lib/main_layout.dart` para el orden exacto de ítems.
const int kPaneLobby = 0;
const int kPaneCatalogo = 1;
const int kPaneMateriales = 2;
const int kPaneCadScanner = 3;
const int kMainPaneImportarExcel = 4;
const int kPaneAuditor = 5;
const int kPaneEstandarizacion = 6;
const int kPaneGestionProyectos = 7;
const int kPaneMapaIngenieria = 8;
const int kPaneVin = 9;
const int kPaneHistorial = 10;
const int kPaneAyudas = 11;
const int kPaneAnalytics = 12;
const int kPaneQa = 13;
const int kPaneRadar = 14;
const int kPaneMrp = 15;
const int kPaneMonitoreo = 16;

/// Footer: Usuarios (solo ADMIN). Siempre antes de Configuración.
const int kPaneUsuariosAdmin = 17;

/// Footer: Configuración (siempre presente). Con admin, va después de [kPaneUsuariosAdmin].
int kPaneSettingsIndex({required bool isAdmin}) => isAdmin ? 18 : 17;

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
