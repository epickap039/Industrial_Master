import 'package:flutter/foundation.dart';

import 'main_nav.dart';
import 'nav_pane.dart';

/// Visibilidad efectiva de modulos con sondeo HTTP, para pausar timers cuando el
/// rail o el hub no muestran esa pestaña, o cuando la app va a segundo plano.
class ShellPollGates {
  ShellPollGates._();

  /// Centro de monitoreo embebido en "Operacion diaria" (IndexedStack del hub).
  static final ValueNotifier<bool> monitoreoOperacionHubVisible =
      ValueNotifier<bool>(false);

  /// Centro de monitoreo como item propio del rail lateral.
  static final ValueNotifier<bool> monitoreoTopRailVisible =
      ValueNotifier<bool>(false);

  /// Chat interno dentro del hub Operacion.
  static final ValueNotifier<bool> internalChatHttpVisible =
      ValueNotifier<bool>(false);

  /// App en primer plano (resumed).
  static final ValueNotifier<bool> appForeground = ValueNotifier<bool>(true);

  static void sync({
    required int topRailIndex,
    required NavPaneId? activeLeafPane,
  }) {
    final ar = MainNav.currentRole;
    final top = navPaneAtIndex(topRailIndex, ar);
    monitoreoOperacionHubVisible.value =
        top == NavPaneId.operacionHub &&
        activeLeafPane == NavPaneId.centroMonitoreo;
    monitoreoTopRailVisible.value = top == NavPaneId.centroMonitoreo;
    internalChatHttpVisible.value =
        top == NavPaneId.operacionHub &&
        activeLeafPane == NavPaneId.chatInterno;
  }

  static void setAppForeground(bool value) {
    if (appForeground.value != value) {
      appForeground.value = value;
    }
  }

  /// Tras cerrar sesion: detiene sondeos dependientes del shell.
  static void resetNavigationGates() {
    monitoreoOperacionHubVisible.value = false;
    monitoreoTopRailVisible.value = false;
    internalChatHttpVisible.value = false;
    appForeground.value = true;
  }
}
