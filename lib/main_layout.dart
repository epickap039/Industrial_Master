import 'package:fluent_ui/fluent_ui.dart';

import 'screens/analytics_screen.dart';
import 'screens/arbitration.dart';
import 'screens/auditor.dart';
import 'screens/ayudas_visuales/ayudas_visuales_nav.dart';
import 'screens/cad_scanner_screen.dart';
import 'screens/catalog.dart';
import 'screens/code_generator_screen.dart';
import 'screens/engineering_map.dart';
import 'screens/history.dart';
import 'screens/impact_radar_screen.dart';
import 'screens/internal_chat_screen.dart';
import 'screens/lobby_screen.dart';
import 'screens/materials_list.dart';
import 'screens/monitoreo_tareas_screen.dart';
import 'screens/mrp_screen.dart';
import 'screens/project_management.dart';
import 'screens/qa_dashboard.dart';
import 'screens/settings.dart';
import 'screens/standardization.dart';
import 'screens/version_notes_timeline_screen.dart';
import 'screens/vin_dossier.dart';
import 'services/app_role.dart';
import 'services/nav_pane.dart';
import 'theme/ui_tokens.dart';
import 'widgets/constrained_app_body.dart';

NavigationPane buildIndustrialNavigationPane({
  required int selected,
  required ValueChanged<int> onPaneChanged,
  required ValueChanged<int> onItemPressed,
  required PaneDisplayMode displayMode,
  bool toggleable = false,
  required int? targetRevisionId,
  required void Function(NavPaneId id, {int? revisionId}) onNavigatePane,
  required NavPaneId? requestedPaneId,
  required ValueChanged<NavPaneId?> onActiveLeafPaneChanged,
  required String userRole,
  required VoidCallback onThemeTap,
  required VoidCallback onBugTap,
}) {
  Widget paneBody(Widget child) => _PaneBodyViewport(child: child);

  final ar = parseAppRole(userRole);
  final operacionModules = <_SectionModule>[
    if (ar.showsNavAyudas)
      _SectionModule(
        id: NavPaneId.ayudasVisuales,
        title: 'Ayudas visuales',
        icon: FluentIcons.page_list,
        body: ConstrainedAppBody(
          child: AyudasVisualesNav(
            canUpload: ar.ayudasCanUpload,
            canEditCategoryImage: ar.ayudasCanEditCategoryImage,
            allowRevisionHistory: ar.ayudasShowRevisionHistory,
          ),
        ),
      ),
    if (ar.showsNavChatInterno)
      const _SectionModule(
        id: NavPaneId.chatInterno,
        title: 'Chat interno',
        icon: FluentIcons.chat,
        body: InternalChatScreen(),
      ),
    if (ar.showsNavMateriales)
      const _SectionModule(
        id: NavPaneId.materialesOficiales,
        title: 'Materiales oficiales',
        icon: FluentIcons.set_action,
        body: MaterialsListScreen(),
      ),
    if (ar.showsNavRadar)
      const _SectionModule(
        id: NavPaneId.radarImpacto,
        title: 'Radar de impacto',
        icon: FluentIcons.build_issue,
        body: ImpactRadarScreen(),
      ),
    if (ar.showsNavMonitoreo)
      _SectionModule(
        id: NavPaneId.centroMonitoreo,
        title: 'Centro de monitoreo',
        icon: FluentIcons.activity_feed,
        body: MonitoreoTareasScreen(effectiveRole: userRole),
      ),
  ];

  final ingenieriaModules = <_SectionModule>[
    if (ar.showsNavGestionProyectos)
      const _SectionModule(
        id: NavPaneId.gestionProyectos,
        title: 'Gestión de proyectos',
        icon: FluentIcons.fabric_folder,
        body: ProjectManagementScreen(),
      ),
    if (ar.showsNavVin)
      _SectionModule(
        id: NavPaneId.expedientesVin,
        title: 'Expedientes VIN',
        icon: FluentIcons.car,
        body: VINDossierScreen(
          onNavigateToBOM: (id) =>
              onNavigatePane(NavPaneId.mapaIngenieria, revisionId: id),
        ),
      ),
    if (ar.showsNavCadScanner)
      const _SectionModule(
        id: NavPaneId.escanerCad,
        title: 'Escáner CAD',
        icon: FluentIcons.cube_shape,
        body: CADScannerScreen(),
      ),
    if (ar.showsNavImportarExcel)
      const _SectionModule(
        id: NavPaneId.importarExcel,
        title: 'Importar Excel',
        icon: FluentIcons.cloud,
        body: ArbitrationScreen(),
      ),
    if (ar.showsNavAuditor)
      const _SectionModule(
        id: NavPaneId.auditorArchivos,
        title: 'Auditor de archivos',
        icon: FluentIcons.check_list,
        body: AuditorScreen(),
      ),
    if (ar.showsNavEstandarizacion)
      _SectionModule(
        id: NavPaneId.estandarizacion,
        title: 'Estandarización',
        icon: FluentIcons.filter,
        body: ConstrainedAppBody(
          child: StandardizationScreen(),
        ),
      ),
    if (ar.showsNavCatalogo)
      const _SectionModule(
        id: NavPaneId.generadorCodigo,
        title: 'Generador de Código',
        icon: FluentIcons.cube_shape,
        body: ConstrainedAppBody(
          child: CodeGeneratorScreen(),
        ),
      ),
  ];

  final seguimientoModules = <_SectionModule>[
    if (ar.showsNavHistorialCambios)
      const _SectionModule(
        id: NavPaneId.historialCambios,
        title: 'Historial de cambios',
        icon: FluentIcons.history,
        body: HistoryScreen(),
      ),
    if (ar.showsNavQa)
      _SectionModule(
        id: NavPaneId.centroQa,
        title: 'Centro de QA',
        icon: FluentIcons.tablet,
        body: ConstrainedAppBody(
          child: QADashboardScreen(effectiveRole: userRole),
        ),
      ),
    if (ar.showsNavQa)
      const _SectionModule(
        id: NavPaneId.notasVersion,
        title: 'Notas de versión',
        icon: FluentIcons.history,
        body: ConstrainedAppBody(
          child: VersionNotesTimelineScreen(),
        ),
      ),
  ];

  final datosModules = <_SectionModule>[
    if (ar.showsNavCatalogo)
      _SectionModule(
        id: NavPaneId.catalogoMaestro,
        title: 'Catálogo maestro',
        icon: FluentIcons.database,
        body: CatalogScreen(effectiveRole: userRole),
      ),
    if (ar.showsNavAnalytics)
      const _SectionModule(
        id: NavPaneId.dashboardAnalytics,
        title: 'Estadísticas',
        icon: FluentIcons.pie_single,
        body: ConstrainedAppBody(
          child: AnalyticsScreen(),
        ),
      ),
    if (ar.showsNavMrp)
      const _SectionModule(
        id: NavPaneId.requerimientosMrp,
        title: 'Requerimientos (MRP)',
        icon: FluentIcons.shopping_cart,
        body: MRPScreen(),
      ),
  ];

  final items = <NavigationPaneItem>[
    if (ar.showsNavLobby)
      PaneItem(
        icon: const Icon(FluentIcons.home),
        title: const Text('Lobby principal'),
        body: paneBody(
          LobbyScreen(
            effectiveRole: userRole,
            isAdmin: ar.isAdminRail,
            onNavigatePane: onNavigatePane,
          ),
        ),
      ),
    if (operacionModules.isNotEmpty)
      PaneItem(
        icon: const Icon(FluentIcons.page_list),
        title: const Text('Operación diaria'),
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Operación diaria',
            modules: operacionModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
          ),
        ),
      ),
    if (ingenieriaModules.isNotEmpty)
      PaneItem(
        icon: const Icon(FluentIcons.developer_tools),
        title: const Text('Ingeniería y cambios'),
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Ingeniería y cambios',
            modules: ingenieriaModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
          ),
        ),
      ),
    if (seguimientoModules.isNotEmpty)
      PaneItem(
        icon: const Icon(FluentIcons.health),
        title: const Text('Seguimiento e incidentes'),
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Seguimiento e incidentes',
            modules: seguimientoModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
          ),
        ),
      ),
    if (datosModules.isNotEmpty)
      PaneItem(
        icon: const Icon(FluentIcons.database),
        title: const Text('Datos y catálogos'),
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Datos y catálogos',
            modules: datosModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
          ),
        ),
      ),
    if (ar.showsNavMonitoreo)
      PaneItem(
        icon: const Icon(FluentIcons.activity_feed),
        title: const Text('Centro de monitoreo'),
        body: paneBody(
          MonitoreoTareasScreen(effectiveRole: userRole),
        ),
      ),
    if (ar.showsNavMapaIngenieria)
      PaneItem(
        icon: const Icon(FluentIcons.map_layers),
        title: const Text('Mapa de ingeniería'),
        body: paneBody(EngineeringMapScreen(targetRevisionId: targetRevisionId)),
      ),
  ];

  return NavigationPane(
    selected: selected,
    onChanged: onPaneChanged,
    onItemPressed: onItemPressed,
    displayMode: displayMode,
    toggleable: toggleable,
    size: const NavigationPaneSize(openWidth: 256),
    items: items,
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
      if (ar.showsFooterConfiguracion)
        PaneItem(
          icon: const Icon(FluentIcons.settings),
          title: const Text('Configuración'),
          body: paneBody(
            const ConstrainedAppBody(
              child: SettingsScreen(),
            ),
          ),
        ),
    ],
  );
}

class _SectionModule {
  const _SectionModule({
    required this.id,
    required this.title,
    required this.icon,
    required this.body,
  });

  final NavPaneId id;
  final String title;
  final IconData icon;
  final Widget body;
}

class _SectionHubScreen extends StatefulWidget {
  const _SectionHubScreen({
    required this.sectionTitle,
    required this.modules,
    required this.requestedPaneId,
    required this.onActiveLeafPaneChanged,
  });

  final String sectionTitle;
  final List<_SectionModule> modules;
  final NavPaneId? requestedPaneId;
  final ValueChanged<NavPaneId?> onActiveLeafPaneChanged;

  @override
  State<_SectionHubScreen> createState() => _SectionHubScreenState();
}

class _SectionHubScreenState extends State<_SectionHubScreen> {
  void _notifyLeafSelection() {
    if (widget.modules.isEmpty) {
      widget.onActiveLeafPaneChanged(null);
      return;
    }
    final idx = _selected.clamp(0, widget.modules.length - 1);
    widget.onActiveLeafPaneChanged(widget.modules[idx].id);
  }

  int _selected = 0;
  int? _hoveredIdx;

  @override
  void initState() {
    super.initState();
    _applyRequested();
  }

  @override
  void didUpdateWidget(covariant _SectionHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requestedPaneId != widget.requestedPaneId ||
        oldWidget.modules.length != widget.modules.length) {
      _applyRequested();
    }
  }

  void _applyRequested() {
    final req = widget.requestedPaneId;
    if (req != null) {
      final idx = widget.modules.indexWhere((m) => m.id == req);
      if (idx >= 0) {
        _selected = idx;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyLeafSelection();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final selectedIdx =
        _selected.clamp(0, widget.modules.isEmpty ? 0 : widget.modules.length - 1);
    final hubChrome = shellNavChromeBackground(theme);
    final hubDivider = theme.brightness == Brightness.dark
        ? const Color(0xFF2A3140)
        : theme.resources.controlStrokeColorDefault.withValues(alpha: 0.55);
    const hubTabShape = WidgetStatePropertyAll<RoundedRectangleBorder>(
      RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    );
    final selectedStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      shape: hubTabShape,
      backgroundColor: WidgetStatePropertyAll(
        theme.accentColor.withValues(alpha: 0.22),
      ),
      foregroundColor: WidgetStatePropertyAll(theme.accentColor),
    );
    final compactStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      shape: hubTabShape,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: hubChrome,
            border: Border(
              bottom: BorderSide(color: hubDivider, width: 1),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: UiTokens.pageHPadding,
              vertical: 6,
            ),
            child: Row(
              children: [
                for (var i = 0; i < widget.modules.length; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  MouseRegion(
                    onEnter: (_) => setState(() => _hoveredIdx = i),
                    onExit: (_) {
                      if (_hoveredIdx == i) setState(() => _hoveredIdx = null);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 130),
                      curve: Curves.easeOut,
                      transform:
                          _hoveredIdx == i && i != selectedIdx
                              ? (Matrix4.identity()..translate(0.0, -1.0))
                              : Matrix4.identity(),
                      decoration: BoxDecoration(
                        boxShadow:
                            _hoveredIdx == i && i != selectedIdx
                                ? [
                                  BoxShadow(
                                    color:
                                        theme.brightness == Brightness.dark
                                            ? const Color(0x33000000)
                                            : const Color(0x1F0F172A),
                                    blurRadius: 5,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                                : null,
                      ),
                      child: Button(
                        style: i == selectedIdx ? selectedStyle : compactStyle,
                        onPressed: () => setState(() {
                          _selected = i;
                          _notifyLeafSelection();
                        }),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(widget.modules[i].icon, size: 13),
                            const SizedBox(width: 5),
                            Text(
                              widget.modules[i].title,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: selectedIdx,
            children: widget.modules.map((m) => m.body).toList(),
          ),
        ),
      ],
    );
  }
}

class _PaneBodyViewport extends StatelessWidget {
  const _PaneBodyViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final spacing = bottomInset > 0 ? bottomInset + 12 : 18.0;
    return Padding(
      padding: EdgeInsets.only(bottom: spacing),
      child: child,
    );
  }
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
    final screenW = MediaQuery.sizeOf(context).width;
    final comboWidth = screenW < 900 ? 118.0 : (screenW < 1150 ? 138.0 : 160.0);
    final showRoleIcon = screenW >= 840;
    // Mostrar selector solo a Administrador y Desarrollador
    if (role != AppRole.administrador && role != AppRole.desarrollador) {
      return const SizedBox.shrink();
    }
    final v = (simulatedRole == null || simulatedRole!.isEmpty)
        ? kRealSentinel
        : simulatedRole!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: simulatedRole != null && simulatedRole!.isNotEmpty
            ? FluentTheme.of(context).accentColor.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(UiTokens.cardRadius - 4),
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
          if (showRoleIcon)
            Icon(
              FluentIcons.people,
              size: 12,
              color: FluentTheme.of(context).accentColor,
            ),
          if (showRoleIcon) const SizedBox(width: 5),
          SizedBox(
            width: comboWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: ComboBox<String>(
                value: v,
                items: [
                  ComboBoxItem(
                    value: kRealSentinel,
                    child: const Text(
                      'Mi rol',
                      style: TextStyle(fontSize: 10),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const ComboBoxItem(
                    value: 'CALIDAD',
                    child: Text(
                      'Calidad',
                      style: TextStyle(fontSize: 10),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const ComboBoxItem(
                    value: 'PRODUCCION',
                    child: Text(
                      'Producción',
                      style: TextStyle(fontSize: 10),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const ComboBoxItem(
                    value: 'INGENIERIA_METODOS',
                    child: Text(
                      'Ingeniería',
                      style: TextStyle(fontSize: 10),
                      overflow: TextOverflow.ellipsis,
                    ),
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
