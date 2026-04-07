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
import 'services/app_role.dart';
import 'services/nav_pane.dart';
import 'widgets/constrained_app_body.dart';

NavigationPane buildIndustrialNavigationPane({
  required int selected,
  required ValueChanged<int> onPaneChanged,
  required ValueChanged<int> onItemPressed,
  required PaneDisplayMode displayMode,
  bool toggleable = false,
  required int? targetRevisionId,
  required void Function(NavPaneId id, {int? revisionId}) onNavigatePane,
  required String userRole,
  required VoidCallback onThemeTap,
  required VoidCallback onBugTap,
}) {
  final ar = parseAppRole(userRole);

  final PaneItem? lobby = ar.showsNavLobby
      ? PaneItem(
          icon: const Icon(FluentIcons.home),
          title: const Text('Lobby Principal'),
          body: ConstrainedAppBody(
            child: LobbyScreen(
              effectiveRole: userRole,
              isAdmin: ar.isAdminRail,
              onNavigatePane: onNavigatePane,
            ),
          ),
        )
      : null;
  final PaneItem? catalogo = ar.showsNavCatalogo
      ? PaneItem(
          icon: const Icon(FluentIcons.database),
          title: const Text('Catálogo Maestro'),
          body: const CatalogScreen(),
        )
      : null;
  final PaneItem? materiales = ar.showsNavMateriales
      ? PaneItem(
          icon: const Icon(FluentIcons.set_action),
          title: const Text('Materiales Oficiales'),
          body: const MaterialsListScreen(),
        )
      : null;
  final PaneItem? cad = ar.showsNavCadScanner
      ? PaneItem(
          icon: const Icon(FluentIcons.cube_shape),
          title: const Text('Escáner CAD 3D/2D'),
          body: const CADScannerScreen(),
        )
      : null;
  final PaneItem? excel = ar.showsNavImportarExcel
      ? PaneItem(
          icon: const Icon(FluentIcons.cloud),
          title: const Text('Importar Excel'),
          body: const ArbitrationScreen(),
        )
      : null;
  final PaneItem? auditor = ar.showsNavAuditor
      ? PaneItem(
          icon: const Icon(FluentIcons.check_list),
          title: const Text('Auditor de Archivos'),
          body: const AuditorScreen(),
        )
      : null;
  final PaneItem? estandar = ar.showsNavEstandarizacion
      ? PaneItem(
          icon: const Icon(FluentIcons.filter),
          title: const Text('Estandarización'),
          body: ConstrainedAppBody(
            child: StandardizationScreen(),
          ),
        )
      : null;

  final PaneItem? proyectos = ar.showsNavGestionProyectos
      ? PaneItem(
          icon: const Icon(FluentIcons.fabric_folder),
          title: const Text('Gestión de Proyectos'),
          body: const ProjectManagementScreen(),
        )
      : null;
  final PaneItem? mapa = ar.showsNavMapaIngenieria
      ? PaneItem(
          icon: const Icon(FluentIcons.map_layers),
          title: const Text('Mapa de Ingeniería'),
          body: EngineeringMapScreen(
            targetRevisionId: targetRevisionId,
          ),
        )
      : null;
  final PaneItem? vin = ar.showsNavVin
      ? PaneItem(
          icon: const Icon(FluentIcons.car),
          title: const Text('Expedientes VIN'),
          body: VINDossierScreen(
            onNavigateToBOM: (id) =>
                onNavigatePane(NavPaneId.mapaIngenieria, revisionId: id),
          ),
        )
      : null;
  final PaneItem? historial = ar.showsNavHistorialCambios
      ? PaneItem(
          icon: const Icon(FluentIcons.history),
          title: const Text('Historial de Cambios'),
          body: const HistoryScreen(),
        )
      : null;
  final PaneItem? ayudas = ar.showsNavAyudas
      ? PaneItem(
          icon: const Icon(FluentIcons.page_list),
          title: const Text('Ayudas visuales'),
          body: ConstrainedAppBody(
            child: AyudasVisualesNav(
              canUpload: ar.ayudasCanUpload,
              allowRevisionHistory: ar.ayudasShowRevisionHistory,
            ),
          ),
        )
      : null;

  final PaneItem? analytics = ar.showsNavAnalytics
      ? PaneItem(
          icon: const Icon(FluentIcons.pie_single),
          title: const Text('Dashboard Analytics'),
          body: const ConstrainedAppBody(
            child: AnalyticsScreen(),
          ),
        )
      : null;
  final PaneItem? qa = ar.showsNavQa
      ? PaneItem(
          icon: const Icon(FluentIcons.tablet),
          title: const Text('Centro de QA'),
          body: const ConstrainedAppBody(
            child: QADashboardScreen(),
          ),
        )
      : null;
  final PaneItem? radar = ar.showsNavRadar
      ? PaneItem(
          icon: const Icon(FluentIcons.build_issue),
          title: const Text('Radar de Impacto'),
          body: const ImpactRadarScreen(),
        )
      : null;
  final PaneItem? mrp = ar.showsNavMrp
      ? PaneItem(
          icon: const Icon(FluentIcons.shopping_cart),
          title: const Text('Requerimientos (MRP)'),
          body: const MRPScreen(),
        )
      : null;
  final PaneItem? monitoreo = ar.showsNavMonitoreo
      ? PaneItem(
          icon: const Icon(FluentIcons.activity_feed),
          title: const Text('Centro de Monitoreo'),
          body: MonitoreoTareasScreen(effectiveRole: userRole),
        )
      : null;

  return NavigationPane(
    selected: selected,
    onChanged: onPaneChanged,
    onItemPressed: onItemPressed,
    displayMode: displayMode,
    toggleable: toggleable,
    size: const NavigationPaneSize(openWidth: 240),
    items: _buildNavItems(
      lobby: lobby,
      catalogo: catalogo,
      materiales: materiales,
      cad: cad,
      excel: excel,
      auditor: auditor,
      estandar: estandar,
      proyectos: proyectos,
      mapa: mapa,
      vin: vin,
      historial: historial,
      ayudas: ayudas,
      analytics: analytics,
      qa: qa,
      radar: radar,
      mrp: mrp,
      monitoreo: monitoreo,
    ),
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
      if (ar.isAdminRail)
        PaneItem(
          icon: const Icon(FluentIcons.people),
          title: const Text('Usuarios (admin)'),
          body: ConstrainedAppBody(
            child: const ConfiguracionUsuariosScreen(),
          ),
        ),
      if (ar != AppRole.produccion)
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

List<NavigationPaneItem> _buildNavItems({
  required PaneItem? lobby,
  required PaneItem? catalogo,
  required PaneItem? materiales,
  required PaneItem? cad,
  required PaneItem? excel,
  required PaneItem? auditor,
  required PaneItem? estandar,
  required PaneItem? proyectos,
  required PaneItem? mapa,
  required PaneItem? vin,
  required PaneItem? historial,
  required PaneItem? ayudas,
  required PaneItem? analytics,
  required PaneItem? qa,
  required PaneItem? radar,
  required PaneItem? mrp,
  required PaneItem? monitoreo,
}) {
  final out = <NavigationPaneItem>[];
  void section(String title, List<PaneItem?> paneItems) {
    final list = paneItems.whereType<PaneItem>().toList();
    if (list.isEmpty) return;
    out.add(PaneItemHeader(header: Text(title)));
    out.addAll(list);
  }

  if (lobby != null) out.add(lobby);
  section('Ingeniería', [catalogo, materiales, cad, excel, auditor, estandar]);
  section('Gestión', [proyectos, mapa, vin, historial, ayudas]);
  section('Control', [analytics, qa, radar, mrp]);
  section('Administración', [monitoreo]);
  return out;
}

/// Borde + banner cuando el admin simula otro rol (ver [MainNav] en main.dart).
class SimulationModeShell extends StatelessWidget {
  const SimulationModeShell({
    super.key,
    required this.active,
    required this.effectiveRoleLabel,
    required this.child,
  });

  final bool active;
  final String effectiveRoleLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFFF9800), width: 3),
      ),
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            right: 0,
            top: 72,
            bottom: 72,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 34,
                padding:
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFE65100).withValues(alpha: 0.94),
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(8),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 6,
                      offset: Offset(-2, 0),
                      color: Color(0x44000000),
                    ),
                  ],
                ),
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Text(
                    'MODO SIMULACION · $effectiveRoleLabel',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      height: 1.15,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Combo "Ver como" para la barra superior; solo visible si el rol real es ADMINISTRADOR.
class RoleSimulationAppBarControls extends StatelessWidget {
  const RoleSimulationAppBarControls({
    super.key,
    required this.realRoleRaw,
    required this.simulatedRole,
    required this.onChanged,
  });

  final String realRoleRaw;
  final String? simulatedRole;
  final ValueChanged<String?> onChanged;

  static const String kRealSentinel = '__REAL__';

  @override
  Widget build(BuildContext context) {
    final role = parseAppRole(realRoleRaw);
    // Mostrar selector solo a Administrador y Desarrollador
    if (role != AppRole.administrador && role != AppRole.desarrollador) {
      return const SizedBox.shrink();
    }
    final v = (simulatedRole == null || simulatedRole!.isEmpty)
        ? kRealSentinel
        : simulatedRole!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: simulatedRole != null && simulatedRole!.isNotEmpty
            ? FluentTheme.of(context).accentColor.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: simulatedRole != null && simulatedRole!.isNotEmpty
              ? FluentTheme.of(context).accentColor.withValues(alpha: 0.3)
              : Colors.transparent,
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            FluentIcons.people,
            size: 13,
            color: FluentTheme.of(context).accentColor,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 160,
            child: Align(
              alignment: Alignment.centerLeft,
              child: ComboBox<String>(
                value: v,
                items: [
                  ComboBoxItem(
                    value: kRealSentinel,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          FluentIcons.accept,
                          size: 11,
                          color: FluentTheme.of(context).accentColor,
                        ),
                        const SizedBox(width: 4),
                        const Text('Mi rol', style: TextStyle(fontSize: 10.5)),
                      ],
                    ),
                  ),
                  const ComboBoxItem(
                    value: 'CALIDAD',
                    child: Text('Calidad', style: TextStyle(fontSize: 10.5)),
                  ),
                  const ComboBoxItem(
                    value: 'PRODUCCION',
                    child: Text('Producción', style: TextStyle(fontSize: 10.5)),
                  ),
                  const ComboBoxItem(
                    value: 'INGENIERIA_METODOS',
                    child: Text('Ingeniería', style: TextStyle(fontSize: 10.5)),
                  ),
                ],
                onChanged: (nv) {
                  if (nv == null || nv == kRealSentinel) {
                    onChanged(null);
                  } else {
                    onChanged(nv);
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
