import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_role.dart';
import 'nav_pane.dart';

/// Documento a abrir en el visor al navegar desde el lobby (sin `url_launcher`).
class AyudasLobbyOpenIntent {
  const AyudasLobbyOpenIntent({
    required this.idAyuda,
    required this.idRevision,
    required this.tituloDocumento,
  });

  final int idAyuda;
  final int idRevision;
  final String tituloDocumento;
}

/// Navegación al shell principal ([NavigationView] en `main.dart`).
/// Los índices del rail son **solo paneles visibles** para el rol actual.
class MainNav {
  MainNav._();

  /// [paneId] es el destino lógico (p. ej. [NavPaneId.importarExcel]) cuando el índice
  /// del rail apunta a un hub que agrupa varios módulos.
  static void Function(int index, {NavPaneId? paneId})? _goToPane;
  static String _roleRaw = 'USER';
  /// Solo admin: simula otro rol para filtros de UI (no cambia el token en servidor).
  static String? _simulatedRole;

  static void registerPaneNavigator(
    void Function(int index, {NavPaneId? paneId}) fn,
  ) {
    _goToPane = fn;
  }

  /// Debe llamarse al iniciar sesión o al refrescar el rol (rol real desde prefs).
  static void registerRole(String? rol) {
    _roleRaw = (rol ?? 'USER').trim();
  }

  /// `null` o vacío = usar rol real. Valores típicos: CALIDAD, PRODUCCION, INGENIERIA_METODOS.
  static void setSimulatedRole(String? rol) {
    final s = rol?.trim();
    _simulatedRole = (s == null || s.isEmpty) ? null : s;
  }

  static String get effectiveRoleRaw => _simulatedRole ?? _roleRaw;

  static AppRole get currentRole => parseAppRole(effectiveRoleRaw);

  static bool get isRoleSimulationActive =>
      _simulatedRole != null && _simulatedRole!.isNotEmpty;

  static void goToPane(int index, {NavPaneId? paneId}) =>
      _goToPane?.call(index, paneId: paneId);

  /// Navega al panel lógico si el rol actual lo tiene visible.
  static void goToPaneId(NavPaneId id) {
    final idx = navIndexForPane(id, currentRole);
    if (idx >= 0) _goToPane?.call(idx, paneId: id);
  }

  /// Cierra overlays hasta la ruta raíz y luego selecciona el panel.
  static void goToPanePopOverlays(BuildContext context, NavPaneId id) {
    final nav = Navigator.of(context, rootNavigator: true);
    nav.popUntil((route) => route.isFirst);
    goToPaneId(id);
  }

  static AyudasLobbyOpenIntent? _pendingAyudaLobby;
  static final ValueNotifier<int> ayudaLobbyOpenSignal = ValueNotifier<int>(0);

  /// Encola apertura del visor PDF integrado; [AyudasMenuScreen] consume con [takePendingAyudaLobby].
  static void requestOpenAyudaLobby(AyudasLobbyOpenIntent intent) {
    _pendingAyudaLobby = intent;
    ayudaLobbyOpenSignal.value++;
  }

  static AyudasLobbyOpenIntent? takePendingAyudaLobby() {
    final p = _pendingAyudaLobby;
    _pendingAyudaLobby = null;
    return p;
  }
}
