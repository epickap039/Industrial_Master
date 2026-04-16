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

/// Ancho del panel en modo «plegado» (solo iconos + tooltip).
/// Alineado con el rail compacto de Fluent (~50); padding extra se reduce en [main.dart] vía tema.
const double kNavRailNarrowOpenWidth = 50;

NavigationPane buildIndustrialNavigationPane({
  required int selected,
  required ValueChanged<int> onPaneChanged,
  required ValueChanged<int> onItemPressed,
  required PaneDisplayMode displayMode,
  bool narrowRailSelectedLabelOnly = false,
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
        body: AyudasVisualesNav(
          canUpload: ar.ayudasCanUpload,
          canEditCategoryImage: ar.ayudasCanEditCategoryImage,
          allowRevisionHistory: ar.ayudasShowRevisionHistory,
          allowCrossDocumentCompare: ar.ayudasAllowCrossDocumentCompare,
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
    if (ar.showsNavGeneradorCodigo)
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
      _SectionModule(
        id: NavPaneId.requerimientosMrp,
        title: 'Requerimientos (MRP)',
        icon: FluentIcons.shopping_cart,
        body: MRPScreen(effectiveRole: userRole),
      ),
    if (ar.showsNavOptimizarCorteMp)
      _SectionModule(
        id: NavPaneId.optimizarCorteMp,
        title: 'Optimizar corte MP',
        icon: FluentIcons.processing,
        body: MRPScreen(
          mode: MRPViewMode.optimizacionCorte,
          effectiveRole: userRole,
        ),
      ),
  ];
  final reviewLocksEnabled = ar != AppRole.desarrollador;

  PaneItem railPaneItem({
    required IconData iconData,
    required String label,
    required Widget body,
  }) {
    return PaneItem(
      icon: Tooltip(
        message: label,
        child: Icon(iconData),
      ),
      // Rail estrecho: sin texto en ítems (evita recortes tipo "Operació…"); el tooltip da el nombre.
      title: narrowRailSelectedLabelOnly
          ? null
          : Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      body: body,
    );
  }

  final items = <NavigationPaneItem>[
    if (ar.showsNavLobby)
      railPaneItem(
        iconData: FluentIcons.home,
        label: 'Lobby principal',
        body: paneBody(
          LobbyScreen(
            effectiveRole: userRole,
            isAdmin: ar.isAdminRail,
            onNavigatePane: onNavigatePane,
          ),
        ),
      ),
    if (operacionModules.isNotEmpty)
      railPaneItem(
        iconData: FluentIcons.page_list,
        label: 'Operación diaria',
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Operación diaria',
            modules: operacionModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
            reviewLocksEnabled: reviewLocksEnabled,
          ),
        ),
      ),
    if (ingenieriaModules.isNotEmpty)
      railPaneItem(
        iconData: FluentIcons.developer_tools,
        label: 'Ingeniería y cambios',
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Ingeniería y cambios',
            modules: ingenieriaModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
            reviewLocksEnabled: reviewLocksEnabled,
          ),
        ),
      ),
    if (seguimientoModules.isNotEmpty)
      railPaneItem(
        iconData: FluentIcons.health,
        label: 'Seguimiento e incidentes',
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Seguimiento e incidentes',
            modules: seguimientoModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
            reviewLocksEnabled: reviewLocksEnabled,
          ),
        ),
      ),
    if (datosModules.isNotEmpty)
      railPaneItem(
        iconData: FluentIcons.database,
        label: 'Datos y catálogos',
        body: paneBody(
          _SectionHubScreen(
            sectionTitle: 'Datos y catálogos',
            modules: datosModules,
            requestedPaneId: requestedPaneId,
            onActiveLeafPaneChanged: onActiveLeafPaneChanged,
            reviewLocksEnabled: reviewLocksEnabled,
          ),
        ),
      ),
    if (ar.showsNavMonitoreo)
      railPaneItem(
        iconData: FluentIcons.activity_feed,
        label: 'Centro de monitoreo',
        body: paneBody(
          MonitoreoTareasScreen(effectiveRole: userRole),
        ),
      ),
    if (ar.showsNavMapaIngenieria)
      railPaneItem(
        iconData: FluentIcons.map_layers,
        label: 'Mapa de ingeniería',
        body: paneBody(EngineeringMapScreen(targetRevisionId: targetRevisionId)),
      ),
  ];

  return NavigationPane(
    selected: selected,
    onChanged: onPaneChanged,
    onItemPressed: onItemPressed,
    displayMode: displayMode,
    toggleable: toggleable,
    size: NavigationPaneSize(
      openWidth: narrowRailSelectedLabelOnly ? kNavRailNarrowOpenWidth : 256,
      compactWidth: kNavRailNarrowOpenWidth,
    ),
    items: items,
    footerItems: [
      PaneItemAction(
        icon: Tooltip(
          message: 'Tema visual',
          child: const Icon(FluentIcons.color),
        ),
        title: narrowRailSelectedLabelOnly ? null : const Text('Tema visual'),
        onTap: onThemeTap,
      ),
      PaneItemAction(
        icon: Tooltip(
          message: 'Reportar bug',
          child: const Icon(FluentIcons.bug),
        ),
        title: narrowRailSelectedLabelOnly ? null : const Text('Reportar bug'),
        onTap: onBugTap,
      ),
      if (ar.showsFooterConfiguracion)
        railPaneItem(
          iconData: FluentIcons.settings,
          label: 'Configuración',
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
    required this.reviewLocksEnabled,
  });

  final String sectionTitle;
  final List<_SectionModule> modules;
  final NavPaneId? requestedPaneId;
  final ValueChanged<NavPaneId?> onActiveLeafPaneChanged;
  final bool reviewLocksEnabled;

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
  final Set<int> _loadedModuleIndexes = <int>{};

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
    if (widget.modules.isNotEmpty) {
      _selected = _selected.clamp(0, widget.modules.length - 1);
      _loadedModuleIndexes.add(_selected);
      _loadedModuleIndexes.removeWhere((i) => i >= widget.modules.length);
    } else {
      _selected = 0;
      _loadedModuleIndexes.clear();
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
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(7)),
      ),
    );
    final selectedStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      shape: hubTabShape,
      backgroundColor: WidgetStatePropertyAll(
        theme.accentColor.withValues(alpha: 0.25),
      ),
      foregroundColor: WidgetStatePropertyAll(theme.accentColor),
    );
    final compactStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      shape: hubTabShape,
    );

    final sw = MediaQuery.sizeOf(context).width;
    final sh = MediaQuery.sizeOf(context).height;
    final tabletishWidth = sw < 1100 && sh >= 480;
    final multiModule = widget.modules.length > 1;

    if (widget.modules.isEmpty) {
      return const SizedBox.shrink();
    }

    final selectedModule =
        widget.modules[selectedIdx.clamp(0, widget.modules.length - 1)];
    final hideHubTabsForAyudasCompact =
        selectedModule.id == NavPaneId.ayudasVisuales && tabletishWidth;
    final showSubmoduleTabBar =
        multiModule && !hideHubTabsForAyudasCompact;
    final useCompactHubStrip = multiModule && tabletishWidth;

    Widget hubTabChrome() {
      if (!showSubmoduleTabBar) {
        return const SizedBox.shrink();
      }
      if (useCompactHubStrip) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: hubChrome,
            border: Border(bottom: BorderSide(color: hubDivider, width: 1)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 1,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < widget.modules.length; i++) ...[
                    if (i > 0) const SizedBox(width: 1),
                    Tooltip(
                      message: widget.modules[i].title,
                      child: IconButton(
                        style: ButtonStyle(
                          padding: const WidgetStatePropertyAll(
                            EdgeInsets.all(4),
                          ),
                          backgroundColor: WidgetStateProperty.resolveWith((s) {
                            if (i == selectedIdx) {
                              return theme.accentColor.withValues(alpha: 0.22);
                            }
                            return null;
                          }),
                        ),
                        icon: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.center,
                          children: [
                            Icon(
                              widget.modules[i].icon,
                              size: 17,
                              color: i == selectedIdx
                                  ? theme.accentColor
                                  : theme.typography.body?.color,
                            ),
                            if (widget.reviewLocksEnabled &&
                                navPaneUnderReview(widget.modules[i].id))
                              const Positioned(
                                right: -4,
                                top: -4,
                                child: Icon(FluentIcons.lock, size: 10),
                              ),
                          ],
                        ),
                        onPressed: () => setState(() {
                          _selected = i;
                          _loadedModuleIndexes.add(i);
                          _notifyLeafSelection();
                        }),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          color: hubChrome,
          border: Border(
            bottom: BorderSide(color: hubDivider, width: 1),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
          child: Row(
            children: [
              for (var i = 0; i < widget.modules.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
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
                        _loadedModuleIndexes.add(i);
                        _notifyLeafSelection();
                      }),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(widget.modules[i].icon, size: 12),
                          if (widget.reviewLocksEnabled &&
                              navPaneUnderReview(widget.modules[i].id)) ...[
                            const SizedBox(width: 4),
                            const Icon(FluentIcons.lock, size: 11),
                          ],
                          const SizedBox(width: 5),
                          Text(
                            widget.modules[i].title,
                            style: const TextStyle(fontSize: 11.5),
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
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        hubTabChrome(),
        Expanded(
          child: IndexedStack(
            index: selectedIdx,
            children: [
              for (var i = 0; i < widget.modules.length; i++)
                if (!_loadedModuleIndexes.contains(i))
                  const SizedBox.shrink()
                else
                  widget.reviewLocksEnabled &&
                          navPaneUnderReview(widget.modules[i].id)
                      ? _LockedModulePlaceholder(title: widget.modules[i].title)
                      : widget.modules[i].body,
            ],
          ),
        ),
      ],
    );
  }
}

class _LockedModulePlaceholder extends StatelessWidget {
  const _LockedModulePlaceholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 580),
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: theme.resources.subtleFillColorSecondary,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.resources.controlStrokeColorDefault.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(FluentIcons.lock, size: 24),
            const SizedBox(height: 10),
            Text(
              '$title está en revisión',
              style: theme.typography.subtitle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Este módulo permanece bloqueado temporalmente hasta cerrar QA interno.',
              style: theme.typography.body,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
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
