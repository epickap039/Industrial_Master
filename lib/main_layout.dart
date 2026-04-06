import 'package:fluent_ui/fluent_ui.dart';

import 'screens/analytics_screen.dart';
import 'screens/arbitration.dart';
import 'screens/auditor.dart';
import 'screens/ayudas_visuales/ayudas_visuales_nav.dart';
import 'screens/cad_scanner_screen.dart';
import 'screens/catalog.dart';
import 'screens/configuracion_usuarios_screen.dart';
import 'screens/engineering_map.dart';
import 'screens/history.dart';
import 'screens/impact_radar_screen.dart';
import 'screens/lobby_screen.dart';
import 'screens/materials_list.dart';
import 'screens/monitoreo_tareas_screen.dart';
import 'screens/mrp_screen.dart';
import 'screens/project_management.dart';
import 'screens/qa_dashboard.dart';
import 'screens/settings.dart';
import 'screens/standardization.dart';
import 'screens/vin_dossier.dart';
import 'services/main_nav.dart';
import 'widgets/constrained_app_body.dart';

/// Pane lateral principal: flujo industrial por niveles (Ingeniería → Gestión → Control → Admin).
/// El modo compacto/abierto lo controla [NavigationPane.displayMode] en [main.dart] (botón hamburguesa).
NavigationPane buildIndustrialNavigationPane({
  required int selected,
  required ValueChanged<int> onPaneChanged,
  required ValueChanged<int> onItemPressed,
  required PaneDisplayMode displayMode,
  bool toggleable = false,
  required int? targetRevisionId,
  required void Function(int index, {int? id}) onNavigate,
  required String userRole,
  required VoidCallback onThemeTap,
  required VoidCallback onBugTap,
}) {
  if (userRole == 'QA') {
    return NavigationPane(
      selected: selected,
      onChanged: onPaneChanged,
      onItemPressed: onItemPressed,
      displayMode: displayMode,
      toggleable: toggleable,
      size: const NavigationPaneSize(openWidth: 240),
      items: [
        PaneItem(
          icon: const Icon(FluentIcons.database),
          title: const Text('Catálogo Maestro'),
          body: const CatalogScreen(),
        ),
      ],
    );
  }

  return NavigationPane(
    selected: selected,
    onChanged: onPaneChanged,
    onItemPressed: onItemPressed,
    displayMode: displayMode,
    toggleable: toggleable,
    size: const NavigationPaneSize(openWidth: 240),
    items: [
      PaneItem(
        icon: const Icon(FluentIcons.home),
        title: const Text('Lobby Principal'),
        body: ConstrainedAppBody(
          child: LobbyScreen(
            isAdmin: userRole == 'ADMIN',
            onNavigate: (i) => onNavigate(i),
          ),
        ),
      ),
      PaneItemHeader(header: Text('Ingeniería')),
      PaneItem(
        icon: const Icon(FluentIcons.database),
        title: const Text('Catálogo Maestro'),
        body: const CatalogScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.set_action),
        title: const Text('Materiales Oficiales'),
        body: const MaterialsListScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.cube_shape),
        title: const Text('Escáner CAD 3D/2D'),
        body: const CADScannerScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.cloud),
        title: const Text('Importar Excel'),
        body: const ArbitrationScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.check_list),
        title: const Text('Auditor de Archivos'),
        body: const AuditorScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.filter),
        title: const Text('Estandarización'),
        body: ConstrainedAppBody(
          child: StandardizationScreen(),
        ),
      ),
      PaneItemHeader(header: Text('Gestión')),
      PaneItem(
        icon: const Icon(FluentIcons.fabric_folder),
        title: const Text('Gestión de Proyectos'),
        body: const ProjectManagementScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.map_layers),
        title: const Text('Mapa de Ingeniería'),
        body: EngineeringMapScreen(
          targetRevisionId: targetRevisionId,
        ),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.car),
        title: const Text('Expedientes VIN'),
        body: VINDossierScreen(
          onNavigateToBOM: (id) {
            onNavigate(kPaneMapaIngenieria, id: id);
          },
        ),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.history),
        title: const Text('Historial de Cambios'),
        body: const HistoryScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.page_list),
        title: const Text('Ayudas visuales'),
        body: ConstrainedAppBody(
          child: AyudasVisualesNav(
            canUpload: userRole != 'READONLY',
          ),
        ),
      ),
      PaneItemHeader(header: Text('Control')),
      PaneItem(
        icon: const Icon(FluentIcons.pie_single),
        title: const Text('Dashboard Analytics'),
        body: const ConstrainedAppBody(
          child: AnalyticsScreen(),
        ),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.tablet),
        title: const Text('Centro de QA'),
        body: const ConstrainedAppBody(
          child: QADashboardScreen(),
        ),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.build_issue),
        title: const Text('Radar de Impacto'),
        body: const ImpactRadarScreen(),
      ),
      PaneItem(
        icon: const Icon(FluentIcons.shopping_cart),
        title: const Text('Requerimientos (MRP)'),
        body: const MRPScreen(),
      ),
      PaneItemHeader(header: Text('Administración')),
      PaneItem(
        icon: const Icon(FluentIcons.activity_feed),
        title: const Text('Centro de Monitoreo'),
        body: const MonitoreoTareasScreen(),
      ),
    ],
    footerItems: [
      PaneItemAction(
        icon: const Icon(FluentIcons.color),
        title: const Text('Tema visual'),
        onTap: onThemeTap,
      ),
      PaneItemAction(
        icon: const Icon(FluentIcons.bug),
        title: const Text('Reportar bug'),
        onTap: onBugTap,
      ),
      if (userRole == 'ADMIN')
        PaneItem(
          icon: const Icon(FluentIcons.people),
          title: const Text('Usuarios (admin)'),
          body: ConstrainedAppBody(
            child: const ConfiguracionUsuariosScreen(),
          ),
        ),
      PaneItem(
        icon: const Icon(FluentIcons.settings),
        title: const Text('Configuración'),
        body: const ConstrainedAppBody(
          child: SettingsScreen(),
        ),
      ),
    ],
  );
}
