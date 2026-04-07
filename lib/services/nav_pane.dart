import 'app_role.dart';

enum NavPaneId {
  lobby,
  catalogoMaestro,
  materialesOficiales,
  escanerCad,
  importarExcel,
  auditorArchivos,
  estandarizacion,
  gestionProyectos,
  mapaIngenieria,
  expedientesVin,
  historialCambios,
  ayudasVisuales,
  dashboardAnalytics,
  centroQa,
  radarImpacto,
  requerimientosMrp,
  centroMonitoreo,
}

bool _shows(NavPaneId id, AppRole r) => switch (id) {
      NavPaneId.lobby => r.showsNavLobby,
      NavPaneId.catalogoMaestro => r.showsNavCatalogo,
      NavPaneId.materialesOficiales => r.showsNavMateriales,
      NavPaneId.escanerCad => r.showsNavCadScanner,
      NavPaneId.importarExcel => r.showsNavImportarExcel,
      NavPaneId.auditorArchivos => r.showsNavAuditor,
      NavPaneId.estandarizacion => r.showsNavEstandarizacion,
      NavPaneId.gestionProyectos => r.showsNavGestionProyectos,
      NavPaneId.mapaIngenieria => r.showsNavMapaIngenieria,
      NavPaneId.expedientesVin => r.showsNavVin,
      NavPaneId.historialCambios => r.showsNavHistorialCambios,
      NavPaneId.ayudasVisuales => r.showsNavAyudas,
      NavPaneId.dashboardAnalytics => r.showsNavAnalytics,
      NavPaneId.centroQa => r.showsNavQa,
      NavPaneId.radarImpacto => r.showsNavRadar,
      NavPaneId.requerimientosMrp => r.showsNavMrp,
      NavPaneId.centroMonitoreo => r.showsNavMonitoreo,
    };

const List<NavPaneId> kNavPaneOrder = [
  NavPaneId.lobby,
  NavPaneId.catalogoMaestro,
  NavPaneId.materialesOficiales,
  NavPaneId.escanerCad,
  NavPaneId.importarExcel,
  NavPaneId.auditorArchivos,
  NavPaneId.estandarizacion,
  NavPaneId.gestionProyectos,
  NavPaneId.mapaIngenieria,
  NavPaneId.expedientesVin,
  NavPaneId.historialCambios,
  NavPaneId.ayudasVisuales,
  NavPaneId.dashboardAnalytics,
  NavPaneId.centroQa,
  NavPaneId.radarImpacto,
  NavPaneId.requerimientosMrp,
  NavPaneId.centroMonitoreo,
];

List<NavPaneId> visibleNavPanes(AppRole r) =>
    kNavPaneOrder.where((id) => _shows(id, r)).toList(growable: false);

int navIndexForPane(NavPaneId id, AppRole r) {
  final v = visibleNavPanes(r);
  return v.indexOf(id);
}

NavPaneId? navPaneAtIndex(int index, AppRole r) {
  final v = visibleNavPanes(r);
  if (index < 0 || index >= v.length) return null;
  return v[index];
}
