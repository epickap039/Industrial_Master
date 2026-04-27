import 'app_role.dart';

enum NavPaneId {
  lobby,
  operacionHub,
  ingenieriaHub,
  seguimientoHub,
  datosHub,
  catalogoMaestro,
  materialesOficiales,
  escanerCad,
  importarExcel,
  bomDespiece,
  auditorArchivos,
  estandarizacion,
  gestionProyectos,
  mapaIngenieria,
  expedientesVin,
  historialCambios,
  ayudasVisuales,
  chatInterno,
  dashboardAnalytics,
  centroQa,
  notasVersion,
  radarImpacto,
  requerimientosMrp,
  optimizarCorteMp,
  generadorCodigo,
  centroMonitoreo,
}

bool _shows(NavPaneId id, AppRole r) => switch (id) {
      NavPaneId.lobby => r.showsNavLobby,
      NavPaneId.operacionHub =>
        r.showsNavAyudas ||
        r.showsNavChatInterno ||
        r.showsNavMateriales ||
        r.showsNavRadar ||
        r.showsNavMonitoreo,
      NavPaneId.ingenieriaHub =>
        r.showsNavGestionProyectos ||
        r.showsNavVin ||
        r.showsNavMateriales ||
        r.showsNavCadScanner ||
        r.showsNavImportarExcel ||
        r.showsNavBomDespiece ||
        r.showsNavAuditor ||
        r.showsNavEstandarizacion ||
        r.showsNavHistorialCambios,
      NavPaneId.seguimientoHub =>
        r.showsNavHistorialCambios || r.showsNavQa,
      NavPaneId.datosHub =>
        r.showsNavCatalogo || r.showsNavAnalytics || r.showsNavMrp,
      NavPaneId.catalogoMaestro => r.showsNavCatalogo,
      NavPaneId.materialesOficiales => r.showsNavMateriales,
      NavPaneId.escanerCad => r.showsNavCadScanner,
      NavPaneId.importarExcel => r.showsNavImportarExcel,
      NavPaneId.bomDespiece => r.showsNavBomDespiece,
      NavPaneId.auditorArchivos => r.showsNavAuditor,
      NavPaneId.estandarizacion => r.showsNavEstandarizacion,
      NavPaneId.gestionProyectos => r.showsNavGestionProyectos,
      NavPaneId.mapaIngenieria => r.showsNavMapaIngenieria,
      NavPaneId.expedientesVin => r.showsNavVin,
      NavPaneId.historialCambios => r.showsNavHistorialCambios,
      NavPaneId.ayudasVisuales => r.showsNavAyudas,
      NavPaneId.chatInterno => r.showsNavChatInterno,
      NavPaneId.dashboardAnalytics => r.showsNavAnalytics,
      NavPaneId.centroQa => r.showsNavQa,
      NavPaneId.notasVersion => r.showsNavQa,
      NavPaneId.radarImpacto => r.showsNavRadar,
      NavPaneId.requerimientosMrp => r.showsNavMrp,
      NavPaneId.optimizarCorteMp => r.showsNavOptimizarCorteMp,
      NavPaneId.generadorCodigo => r.showsNavGeneradorCodigo,
      NavPaneId.centroMonitoreo => r.showsNavMonitoreo,
    };

const List<NavPaneId> kNavPaneOrder = [
  NavPaneId.lobby,
  NavPaneId.operacionHub,
  NavPaneId.ingenieriaHub,
  NavPaneId.seguimientoHub,
  NavPaneId.datosHub,
  NavPaneId.centroMonitoreo,
  NavPaneId.mapaIngenieria,
];

// Ingeniería: cuerpo bloqueado (_LockedModulePlaceholder). Desarrollador: acceso completo.
const Set<NavPaneId> kNavPaneIdsUnderReview = <NavPaneId>{
  NavPaneId.expedientesVin,
  NavPaneId.generadorCodigo,
  NavPaneId.bomDespiece,
  NavPaneId.requerimientosMrp,
  NavPaneId.optimizarCorteMp,
};

bool navPaneUnderReview(NavPaneId id) => kNavPaneIdsUnderReview.contains(id);

List<NavPaneId> visibleNavPanes(AppRole r) =>
    kNavPaneOrder.where((id) => _shows(id, r)).toList(growable: false);

NavPaneId _ownerSectionFor(NavPaneId id) {
  return switch (id) {
    NavPaneId.ayudasVisuales ||
    NavPaneId.chatInterno ||
    NavPaneId.materialesOficiales ||
    NavPaneId.radarImpacto ||
    NavPaneId.centroMonitoreo => NavPaneId.operacionHub,
    NavPaneId.gestionProyectos ||
    NavPaneId.expedientesVin ||
    NavPaneId.escanerCad ||
    NavPaneId.importarExcel ||
    NavPaneId.bomDespiece ||
    NavPaneId.auditorArchivos ||
    NavPaneId.estandarizacion => NavPaneId.ingenieriaHub,
    NavPaneId.historialCambios || NavPaneId.centroQa || NavPaneId.notasVersion => NavPaneId.seguimientoHub,
    NavPaneId.catalogoMaestro ||
    NavPaneId.dashboardAnalytics ||
    NavPaneId.requerimientosMrp ||
    NavPaneId.optimizarCorteMp ||
    NavPaneId.generadorCodigo => NavPaneId.datosHub,
    _ => id,
  };
}

int navIndexForPane(NavPaneId id, AppRole r) {
  final v = visibleNavPanes(r);
  final direct = v.indexOf(id);
  if (direct >= 0) return direct;
  final owner = _ownerSectionFor(id);
  return v.indexOf(owner);
}

NavPaneId? navPaneAtIndex(int index, AppRole r) {
  final v = visibleNavPanes(r);
  if (index < 0 || index >= v.length) return null;
  return v[index];
}

/// Acceso real al panel [id] (no basta con ver el hub contenedor).
bool navLeafRoleAllowed(NavPaneId id, AppRole r) => _shows(id, r);
